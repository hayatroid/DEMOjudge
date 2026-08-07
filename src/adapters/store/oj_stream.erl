%% The stream is configured KEYS_ONLY, so a record says the log moved and not
%% what moved, and every subscriber goes back to the log at its own seq.

-module(oj_stream).

-export([subscribe/1, pause/2]).

-define(NAME, oj_stream_reader).
-define(IDLE_MS, 500).      %% Wait this long after GetRecords comes back empty.
-define(SHARDS_MS, 15000).  %% Look this often for shards that opened since.


subscribe(Table) ->
    case reader(Table) of
        undefined ->
            nil;
        Pid ->
            _ = erlang:monitor(process, Pid),
            Pid ! {listen, self()},
            nil
    end.

pause(Table, Ms) ->
    receive
        moved ->
            drain(),
            moved;
        %% Both ends monitor, so a subscription that can no longer be notified
        %% falls back to polling instead of going silent.
        {'DOWN', _, process, _, _} ->
            timer:sleep(Ms),
            subscribe(Table),
            moved
    after Ms ->
        timed_out
    end.

drain() ->
    receive moved -> drain() after 0 -> ok end.


reader(Table) ->
    case whereis(?NAME) of
        undefined -> start(Table);
        Pid -> Pid
    end.

start(Table) ->
    Pid = spawn(fun() -> read(Table) end),
    try
        register(?NAME, Pid),
        Pid
    catch
        error:badarg ->
            exit(Pid, kill),
            whereis(?NAME)
    end.

read(Table) ->
    Arn = arn(Table),
    loop(Arn, iterators(Arn, #{}), [], now_ms() + ?SHARDS_MS).

loop(Arn, Iters, Listeners, Resharded) ->
    Heard = listen(Listeners),
    {Fresh, Moved} = poll(maps:to_list(Iters), #{}, false),
    case Moved of
        true -> notify(Heard);
        false -> timer:sleep(?IDLE_MS)
    end,
    Now = now_ms(),
    case Now >= Resharded orelse map_size(Fresh) =:= 0 of
        true -> loop(Arn, iterators(Arn, Fresh), Heard, Now + ?SHARDS_MS);
        false -> loop(Arn, Fresh, Heard, Resharded)
    end.

listen(Listeners) ->
    receive
        {listen, Pid} ->
            case lists:keymember(Pid, 1, Listeners) of
                true -> listen(Listeners);
                false -> listen([{Pid, erlang:monitor(process, Pid)} | Listeners])
            end;
        {'DOWN', _, process, Pid, _} ->
            listen(lists:keydelete(Pid, 1, Listeners))
    after 0 ->
        Listeners
    end.

notify(Listeners) ->
    _ = [Pid ! moved || {Pid, _} <- Listeners],
    ok.

poll([], Acc, Moved) ->
    {Acc, Moved};
poll([{Shard, Iterator} | Rest], Acc, Moved) ->
    case records(Iterator) of
        {ok, Records, Next} ->
            poll(Rest, carry(Acc, Shard, Next), Moved orelse Records =/= []);
        stale ->
            poll(Rest, Acc, Moved)
    end.

%% carry drops a shard with no next iterator: it is closed and fully read.
carry(Acc, _Shard, undefined) -> Acc;
carry(Acc, Shard, Iterator) -> Acc#{Shard => Iterator}.


records(Iterator) ->
    Body = #{<<"ShardIterator">> => Iterator, <<"Limit">> => 100},
    case oj_sigv4:call(streams, <<"GetRecords">>, Body) of
        {ok, Answer} ->
            {ok, maps:get(<<"Records">>, Answer, []),
             maps:get(<<"NextShardIterator">>, Answer, undefined)};
        {error, {aws, <<"ExpiredIteratorException">>, _}} -> stale;
        {error, {aws, <<"TrimmedDataAccessException">>, _}} -> stale;
        Other -> error({stream, records, Other})
    end.

iterators(Arn, Have) ->
    lists:foldl(fun(Shard, Acc) ->
                    case maps:is_key(Shard, Acc) of
                        true -> Acc;
                        false -> Acc#{Shard => iterator(Arn, Shard)}
                    end
                end,
                Have,
                open(Arn)).

iterator(Arn, Shard) ->
    Body = #{<<"StreamArn">> => Arn,
             <<"ShardId">> => Shard,
             <<"ShardIteratorType">> => <<"LATEST">>},
    case oj_sigv4:call(streams, <<"GetShardIterator">>, Body) of
        {ok, #{<<"ShardIterator">> := Iterator}} -> Iterator;
        Other -> error({stream, iterator, Other})
    end.

%% A shard with an end has stopped taking writes.
open(Arn) ->
    [maps:get(<<"ShardId">>, Shard)
     || Shard <- shards(Arn, undefined, []),
        not maps:is_key(<<"EndingSequenceNumber">>,
                        maps:get(<<"SequenceNumberRange">>, Shard, #{}))].

shards(Arn, From, Acc) ->
    Told = describe(Arn, From),
    Seen = Acc ++ maps:get(<<"Shards">>, Told, []),
    case maps:get(<<"LastEvaluatedShardId">>, Told, none) of
        none -> Seen;
        Next -> shards(Arn, Next, Seen)
    end.

describe(Arn, From) ->
    Body = case From of
               undefined -> #{<<"StreamArn">> => Arn};
               _ -> #{<<"StreamArn">> => Arn, <<"ExclusiveStartShardId">> => From}
           end,
    case oj_sigv4:call(streams, <<"DescribeStream">>, Body) of
        {ok, #{<<"StreamDescription">> := Told}} -> Told;
        Other -> error({stream, describe, Other})
    end.

%% ListStreams answers with every stream the table has ever had.
arn(Table) ->
    case oj_sigv4:call(streams, <<"ListStreams">>, #{<<"TableName">> => Table}) of
        {ok, Answer} ->
            enabled([maps:get(<<"StreamArn">>, One)
                     || One <- maps:get(<<"Streams">>, Answer, [])]);
        Other ->
            error({stream, list, Other})
    end.

enabled([]) ->
    error({stream, no_enabled_stream});
enabled([Arn | Rest]) ->
    case maps:get(<<"StreamStatus">>, describe(Arn, undefined), <<>>) of
        <<"ENABLED">> -> Arn;
        _ -> enabled(Rest)
    end.

now_ms() ->
    erlang:system_time(millisecond).
