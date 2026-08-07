-module(oj_ddb).

%% One append is one TransactWriteItems, and attribute_not_exists(sk) settles
%% the race for the seq the writer proposed.
%% Each operation answers a retryable failure with a value that is still true, or
%% else raises.

-export([read/2, write/7, peek/1, acquire/4, stow/3, source/2]).

%% DynamoDB deletes an expired item lazily, so the lease item is kept this much
%% longer than its deadline and expiry is read off leased_until, never off TTL.
-define(LEASE_TTL_SECS, 300).

-export([refusal/3]).

read(Table, From) ->
    query(Table, key(From + 1), []).

query(Table, Low, Acc) ->
    Request = #{<<"TableName">> => Table,
                <<"ConsistentRead">> => true,
                <<"KeyConditionExpression">> =>
                    <<"pk = :pk AND sk BETWEEN :low AND :high">>,
                <<"ExpressionAttributeValues">> =>
                    #{<<":pk">> => #{<<"S">> => <<"LOG">>},
                      <<":low">> => #{<<"S">> => Low},
                      %% "~" sorts above every E# key and below "U#", so the
                      %% dedup items stay out of the scan.
                      <<":high">> => #{<<"S">> => <<"E#~">>}}},
    Body = case Acc of
               {start, Key} -> Request#{<<"ExclusiveStartKey">> => Key};
               _ -> Request
           end,
    case oj_sigv4:call(<<"Query">>, Body) of
        {ok, Answer} ->
            Lines = [text(maps:get(<<"line">>, Item))
                     || Item <- maps:get(<<"Items">>, Answer, [])],
            case maps:get(<<"LastEvaluatedKey">>, Answer, none) of
                none -> Lines;
                Next -> Lines ++ query(Table, Low, {start, Next})
            end;
        Other ->
            %% Raises even when retryable: [] would read as "the log ends
            %% here" and the fold would believe it.
            error({ddb, query, Other})
    end.

text(#{<<"S">> := Value}) -> Value;
text(#{<<"N">> := Value}) -> Value.

%% write answers "taken" for a retryable failure rather than claiming a write:
%% the writer's re-decide loop is the retry.
write(Table, Seq, Line, Submission, Dedup, Owner, Fenced) ->
    Items = [row(Table, Seq, Line)]
        ++ [dedup(Table, Dedup, Seq) || Dedup =/= <<>>]
        ++ [check(Table, Submission, Owner) || Fenced],
    case oj_sigv4:call(<<"TransactWriteItems">>, #{<<"TransactItems">> => Items}) of
        {ok, _} ->
            <<"written">>;
        {error, {aws, <<"TransactionCanceledException">>, Answer}} ->
            refusal(Answer, Dedup =/= <<>>, Fenced);
        Other ->
            case oj_sigv4:retryable(Other) of
                true -> <<"taken">>;
                false -> error({ddb, write, Other})
            end
    end.

%% A log line is an opaque payload here: only the keys are this module's.
row(Table, Seq, Line) ->
    #{<<"Put">> =>
          #{<<"TableName">> => Table,
            <<"ConditionExpression">> => <<"attribute_not_exists(sk)">>,
            <<"Item">> =>
                #{<<"pk">> => #{<<"S">> => <<"LOG">>},
                  <<"sk">> => #{<<"S">> => key(Seq)},
                  <<"seq">> => #{<<"N">> => integer_to_binary(Seq)},
                  <<"line">> => #{<<"S">> => Line}}}}.

%% The "U#" prefix is this table's key convention, so the caller hands over the
%% meaning and this builds the key.
dedup(Table, Dedup, Seq) ->
    #{<<"Put">> =>
          #{<<"TableName">> => Table,
            <<"ConditionExpression">> => <<"attribute_not_exists(sk)">>,
            <<"Item">> =>
                #{<<"pk">> => #{<<"S">> => <<"LOG">>},
                  <<"sk">> => #{<<"S">> => <<"U#", Dedup/binary>>},
                  <<"for">> => #{<<"N">> => integer_to_binary(Seq)}}}}.

%% now rides in on the calling node's clock, so the fence is judged against it.
check(Table, Submission, Owner) ->
    #{<<"ConditionCheck">> =>
          #{<<"TableName">> => Table,
            <<"Key">> => lease_key(Submission),
            <<"ConditionExpression">> =>
                <<"#o = :me AND leased_until > :now">>,
            <<"ExpressionAttributeNames">> => #{<<"#o">> => <<"owner">>},
            <<"ExpressionAttributeValues">> =>
                #{<<":me">> => #{<<"S">> => Owner},
                  <<":now">> => #{<<"N">> => now_ms()}}}}.

%% CancellationReasons come back positionally; the lease item is read first, so a
%% stale holder learns it is stale.
refusal(Answer, HasDedup, Fenced) ->
    Reasons = [maps:get(<<"Code">>, R, <<"None">>)
               || R <- maps:get(<<"CancellationReasons">>, Answer, [])],
    Failed = fun(Index) ->
        case Index >= 0 andalso length(Reasons) > Index of
            true -> lists:nth(Index + 1, Reasons) =:= <<"ConditionalCheckFailed">>;
            false -> false
        end
    end,
    DedupAt = case HasDedup of true -> 1; false -> -1 end,
    LeaseAt = case {Fenced, HasDedup} of
                  {false, _} -> -1;
                  {true, true} -> 2;
                  {true, false} -> 1
              end,
    case {Failed(LeaseAt), Failed(DedupAt), Failed(0)} of
        {true, _, _} -> <<"lost">>;
        {_, true, _} -> <<"duplicate">>;
        {_, _, true} -> <<"taken">>;
        _ ->
            %% Item-level contention or throttling, not a condition this
            %% module wrote: nothing was committed, so the answer is "taken".
            case lists:any(fun oj_sigv4:retryable_code/1, Reasons) of
                true -> <<"taken">>;
                false -> error({ddb, write, Reasons})
            end
    end.

%% peek answers [] for a retryable failure: nothing durable is written from
%% what it returns.
peek(Table) ->
    Body = #{<<"TableName">> => Table,
             <<"ConsistentRead">> => true,
             <<"KeyConditionExpression">> => <<"pk = :pk">>,
             <<"ExpressionAttributeValues">> =>
                 #{<<":pk">> => #{<<"S">> => <<"LEASE">>}}},
    case oj_sigv4:call(<<"Query">>, Body) of
        {ok, Answer} ->
            [{text(maps:get(<<"sub">>, Item)),
              text(maps:get(<<"owner">>, Item)),
              binary_to_integer(text(maps:get(<<"leased_until">>, Item)))}
             || Item <- maps:get(<<"Items">>, Answer, [])];
        Other ->
            case oj_sigv4:retryable(Other) of
                true -> [];
                false -> error({ddb, peek, Other})
            end
    end.

%% acquire succeeds only when the lease item is free, expired, or already this
%% owner's; a retryable failure answers false rather than claiming it.
acquire(Table, Submission, Owner, Until) ->
    Body = #{<<"TableName">> => Table,
             <<"Key">> => lease_key(Submission),
             <<"UpdateExpression">> =>
                 <<"SET #s = :sub, #o = :me, leased_until = :until, "
                   "expires_at = :gc">>,
             <<"ConditionExpression">> =>
                 <<"attribute_not_exists(pk) OR leased_until < :now "
                   "OR #o = :me">>,
             <<"ExpressionAttributeNames">> =>
                 #{<<"#s">> => <<"sub">>, <<"#o">> => <<"owner">>},
             <<"ExpressionAttributeValues">> =>
                 #{<<":sub">> => #{<<"S">> => Submission},
                   <<":me">> => #{<<"S">> => Owner},
                   <<":until">> => #{<<"N">> => integer_to_binary(Until)},
                   <<":gc">> => #{<<"N">> => integer_to_binary(
                                               Until div 1000
                                               + ?LEASE_TTL_SECS)},
                   <<":now">> => #{<<"N">> => now_ms()}}},
    case oj_sigv4:call(<<"UpdateItem">>, Body) of
        {ok, _} -> true;
        {error, {aws, <<"ConditionalCheckFailedException">>, _}} -> false;
        Other ->
            case oj_sigv4:retryable(Other) of
                true -> false;
                false -> error({ddb, acquire, Other})
            end
    end.

%% stow writes the body outside the log because a log line is fixed fields and
%% cannot carry free text.
stow(Table, Submission, Text) ->
    Body = #{<<"TableName">> => Table,
             <<"ConditionExpression">> => <<"attribute_not_exists(sk)">>,
             <<"Item">> => #{<<"pk">> => #{<<"S">> => <<"SOURCE">>},
                             <<"sk">> => #{<<"S">> => Submission},
                             <<"body">> => #{<<"S">> => Text}}},
    case oj_sigv4:call(<<"PutItem">>, Body) of
        {ok, _} -> nil;
        %% A body already under this id is the one the log points at, so the
        %% later writer of the same id leaves an orphan rather than a swap.
        {error, {aws, <<"ConditionalCheckFailedException">>, _}} -> nil;
        %% Raises even when retryable: nil would read as "the body is stored",
        %% and the line pointing at it is appended right after.
        Other -> error({ddb, stow, Other})
    end.

source(Table, Submission) ->
    Body = #{<<"TableName">> => Table,
             <<"ConsistentRead">> => true,
             <<"Key">> => #{<<"pk">> => #{<<"S">> => <<"SOURCE">>},
                            <<"sk">> => #{<<"S">> => Submission}}},
    case oj_sigv4:call(<<"GetItem">>, Body) of
        {ok, #{<<"Item">> := Item}} -> {ok, text(maps:get(<<"body">>, Item))};
        {ok, _} -> {error, nil};
        %% Raises even when retryable: {error, nil} would read as "no such
        %% body", and the attempt would die over a body that exists.
        Other -> error({ddb, source, Other})
    end.

lease_key(Submission) ->
    #{<<"pk">> => #{<<"S">> => <<"LEASE">>},
      <<"sk">> => #{<<"S">> => Submission}}.

key(Seq) ->
    Digits = integer_to_binary(Seq),
    Pad = binary:copy(<<"0">>, 12 - byte_size(Digits)),
    <<"E#", Pad/binary, Digits/binary>>.

now_ms() ->
    integer_to_binary(erlang:system_time(millisecond)).
