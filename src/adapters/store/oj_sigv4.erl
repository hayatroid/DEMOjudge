%% TODO: drop the failure detector and the credential fetch written out here
%% when the environment can carry a library for each.
-module(oj_sigv4).

-export([call/2, call/3, retryable/1, retryable_code/1]).

%% The table and its stream take one SigV4 service name, with a different host
%% and target prefix each.
-define(SERVICE, <<"dynamodb">>).
-define(CONTENT_TYPE, "application/x-amz-json-1.0").
-define(DEFAULT_REGION, <<"ap-northeast-1">>).
-define(CACHE, {?MODULE, imds_credentials}).
-define(IMDS, "http://169.254.169.254").
-define(IMDS_TIMEOUT, 1000).
-define(IMDS_SKEW, 60).


call(Op, Body) when is_binary(Op) ->
    call(table, Op, Body).

call(Api, Op, Body) when is_binary(Op) ->
    ok = ensure_started(),
    case credentials() of
        {ok, Creds} -> request(Api, Op, Body, Creds);
        {error, Reason} -> {error, Reason}
    end.

request(Api, Op, Body, Creds) ->
    #{access_key_id := AccessKeyId,
      secret_access_key := SecretAccessKey,
      token := Token} = Creds,
    Region = region(),
    {Url, Host} = endpoint(Api, Region),
    Payload = encode(Body),
    Headers = with_token([{<<"content-type">>, <<?CONTENT_TYPE>>},
                          {<<"host">>, Host},
                          {<<"x-amz-target">>, <<(prefix(Api))/binary, Op/binary>>}],
                         Token),
    %% endpoint/2 always ends the URL in "/", and uri_encode_path keeps
    %% aws_signature from encoding that path again.
    Signed = aws_signature:sign_v4(AccessKeyId, SecretAccessKey, Region, ?SERVICE,
                                   calendar:universal_time(), <<"POST">>,
                                   Url, Headers, Payload,
                                   [{uri_encode_path, false}]),
    %% content-type is signed but dropped here, because httpc sends it from its
    %% own argument and a second copy would break the signature.
    Sent = [{string:lowercase(binary_to_list(K)), binary_to_list(V)}
            || {K, V} <- Signed, K =/= <<"content-type">>],
    Result = httpc:request(post,
                           {binary_to_list(Url), Sent, ?CONTENT_TYPE, Payload},
                           [{connect_timeout, 5000}, {timeout, 20000}],
                           [{body_format, binary}]),
    response(Result).

response({ok, {{_, Status, _}, _Headers, Bin}}) ->
    case decode_body(Bin) of
        {ok, Term} when Status =:= 200 -> {ok, Term};
        {ok, Term} -> {error, {aws, error_type(Term), Term}};
        error -> {error, {http, Status, Bin}}
    end;
response({error, Reason}) ->
    {error, Reason}.

decode_body(Bin) ->
    try decode(Bin) of
        Term when is_map(Term) -> {ok, Term};
        _ -> error
    catch
        _:_ -> error
    end.

error_type(Term) ->
    case maps:get(<<"__type">>, Term, undefined) of
        undefined -> <<"UnknownError">>;
        Type -> lists:last(binary:split(Type, <<"#">>, [global]))
    end.

with_token(Headers, undefined) -> Headers;
with_token(Headers, Token) -> [{<<"x-amz-security-token">>, Token} | Headers].


%% retryable means the same request may be sent again unchanged and the durable
%% state has not been observed to move.
retryable({error, Reason}) -> retryable_reason(Reason);
retryable(_) -> false.

retryable_reason({aws, Code, _}) -> retryable_code(Code);
retryable_reason({http, Status, _}) -> Status >= 500 orelse Status =:= 429;
retryable_reason(timeout) -> true;
retryable_reason(closed) -> true;
retryable_reason(socket_closed_remotely) -> true;
retryable_reason({failed_connect, _}) -> true;
retryable_reason(etimedout) -> true;
retryable_reason(econnrefused) -> true;
retryable_reason(econnreset) -> true;
retryable_reason(ehostunreach) -> true;
retryable_reason(enetunreach) -> true;
retryable_reason(nxdomain) -> false;
%% Absent credentials are a configuration fault rather than a retryable failure.
retryable_reason({no_credentials, _}) -> false;
retryable_reason(_) -> false.

%% The DynamoDB API answers with exception names, and CancellationReasons with
%% shorter Code strings.
retryable_code(<<"ProvisionedThroughputExceededException">>) -> true;
retryable_code(<<"ProvisionedThroughputExceeded">>) -> true;
retryable_code(<<"ThrottlingException">>) -> true;
retryable_code(<<"ThrottlingError">>) -> true;
retryable_code(<<"RequestThrottled">>) -> true;
retryable_code(<<"RequestThrottledException">>) -> true;
retryable_code(<<"RequestLimitExceeded">>) -> true;
retryable_code(<<"TransactionConflictException">>) -> true;
retryable_code(<<"TransactionConflict">>) -> true;
retryable_code(<<"TransactionInProgressException">>) -> true;
retryable_code(<<"ItemCollectionSizeLimitExceededException">>) -> true;
retryable_code(<<"LimitExceededException">>) -> true;
retryable_code(<<"InternalServerError">>) -> true;
retryable_code(<<"ServiceUnavailable">>) -> true;
retryable_code(<<"ServiceUnavailableException">>) -> true;
retryable_code(_) -> false.

ensure_started() ->
    {ok, _} = application:ensure_all_started(ssl),
    {ok, _} = application:ensure_all_started(inets),
    ok.


region() ->
    getenv(<<"AWS_REGION">>, ?DEFAULT_REGION).

prefix(table) -> <<"DynamoDB_20120810.">>;
prefix(streams) -> <<"DynamoDBStreams_20120810.">>.

host(table, Region) -> <<"dynamodb.", Region/binary, ".amazonaws.com">>;
host(streams, Region) -> <<"streams.dynamodb.", Region/binary, ".amazonaws.com">>.

%% OJ_ENDPOINT is a local endpoint serving both APIs at one address.
endpoint(Api, Region) ->
    case getenv(<<"OJ_ENDPOINT">>, <<>>) of
        <<>> ->
            Host = host(Api, Region),
            {<<"https://", Host/binary, "/">>, Host};
        Base ->
            [_Scheme, Authority] = binary:split(Base, <<"//">>),
            {<<Base/binary, "/">>, Authority}
    end.

getenv(Name, Default) ->
    case os:getenv(binary_to_list(Name)) of
        false -> Default;
        "" -> Default;
        Value -> list_to_binary(Value)
    end.


credentials() ->
    case {os:getenv("AWS_ACCESS_KEY_ID"), os:getenv("AWS_SECRET_ACCESS_KEY")} of
        {[_ | _] = AccessKeyId, [_ | _] = SecretAccessKey} ->
            {ok, #{access_key_id => list_to_binary(AccessKeyId),
                   secret_access_key => list_to_binary(SecretAccessKey),
                   token => session_token()}};
        _ ->
            cached_credentials()
    end.

session_token() ->
    case os:getenv("AWS_SESSION_TOKEN") of
        [_ | _] = Token -> list_to_binary(Token);
        _ -> undefined
    end.

cached_credentials() ->
    Now = erlang:system_time(second),
    case persistent_term:get(?CACHE, undefined) of
        #{expires_at := ExpiresAt} = Creds when ExpiresAt > Now + ?IMDS_SKEW ->
            {ok, Creds};
        _ ->
            fetch_credentials(Now)
    end.

fetch_credentials(Now) ->
    ok = ensure_started(),
    try
        Token = unwrap(imds_token()),
        Roles = unwrap(imds_get("/latest/meta-data/iam/security-credentials/", Token)),
        Role = hd(binary:split(Roles, <<"\n">>, [global])),
        Path = "/latest/meta-data/iam/security-credentials/" ++ binary_to_list(Role),
        Fields = decode(unwrap(imds_get(Path, Token))),
        Creds = #{access_key_id => maps:get(<<"AccessKeyId">>, Fields),
                  secret_access_key => maps:get(<<"SecretAccessKey">>, Fields),
                  token => maps:get(<<"Token">>, Fields),
                  expires_at => expires_at(Fields, Now)},
        persistent_term:put(?CACHE, Creds),
        {ok, Creds}
    catch
        throw:{imds, Reason} -> {error, {no_credentials, Reason}};
        error:Reason -> {error, {no_credentials, Reason}}
    end.

unwrap({ok, Value}) -> Value;
unwrap({error, Reason}) -> throw({imds, Reason}).

expires_at(Fields, Now) ->
    case maps:get(<<"Expiration">>, Fields, undefined) of
        undefined ->
            Now + 300;
        Expiration ->
            try calendar:rfc3339_to_system_time(binary_to_list(Expiration), [{unit, second}])
            catch _:_ -> Now + 300
            end
    end.

imds_token() ->
    Request = {?IMDS "/latest/api/token",
               [{"x-aws-ec2-metadata-token-ttl-seconds", "21600"}],
               "text/plain",
               <<>>},
    imds_result(httpc:request(put, Request, imds_opts(), [{body_format, binary}])).

imds_get(Path, Token) ->
    Request = {?IMDS ++ Path, [{"x-aws-ec2-metadata-token", binary_to_list(Token)}]},
    imds_result(httpc:request(get, Request, imds_opts(), [{body_format, binary}])).

imds_opts() ->
    [{connect_timeout, ?IMDS_TIMEOUT}, {timeout, ?IMDS_TIMEOUT}].

imds_result({ok, {{_, 200, _}, _Headers, Bin}}) -> {ok, Bin};
imds_result({ok, {{_, Status, _}, _Headers, _Bin}}) -> {error, {status, Status}};
imds_result({error, Reason}) -> {error, Reason}.


encode(Term) -> iolist_to_binary(json:encode(Term)).

decode(Bin) when is_binary(Bin) -> json:decode(Bin).
