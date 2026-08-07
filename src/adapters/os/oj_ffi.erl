-module(oj_ffi).

-export([read_file/1, write_file/2,
         getenv/2, now_ms/0,
         stderr/1, os_pid/0, argv/0, mkdir/1, sh/1,
         listen/1, accept/1, recv/1, tcp_send/2, tcp_close/1, tune/0,
         cache_get/1, cache_put/3,
         trap_set/2, trap_clear/1, traps/0, die/1]).

%% init:stop/1 is asynchronous, so this blocks afterwards and never returns.
die(Status) ->
    init:stop(Status),
    receive after infinity -> nil end.

read_file(Path) ->
    case file:read_file(binary_to_list(Path)) of
        {ok, Bin} -> {ok, Bin};
        {error, _} -> {error, nil}
    end.

write_file(Path, Bin) ->
    ok = filelib:ensure_dir(binary_to_list(Path)),
    ok = file:write_file(binary_to_list(Path), Bin),
    nil.

%% An ets table dies with its creating process, so the reservation table opens
%% under the process that boots the node and not under a request.
tune() ->
    connections(),
    traps_table(),
    nil.

%% httpc defaults to two connections per host, which this node exceeds.
connections() ->
    _ = application:ensure_all_started(inets),
    _ = httpc:set_options([{max_sessions, 20}, {max_keep_alive_length, 100}]).

%% The cache keeps a fleet read per streaming round from becoming an AWS call
%% per open stream.
cache_get(Key) ->
    Now = erlang:system_time(millisecond),
    case ets:whereis(oj_cache) of
        undefined -> {error, nil};
        _ ->
            case ets:lookup(oj_cache, Key) of
                [{_, Until, Value}] when Until > Now -> {ok, Value};
                _ -> {error, nil}
            end
    end.

cache_put(Key, Value, Ms) ->
    case ets:whereis(oj_cache) of
        undefined -> catch ets:new(oj_cache, [named_table, public, set]);
        _ -> ok
    end,
    true = ets:insert(oj_cache,
                      {Key, erlang:system_time(millisecond) + Ms, Value}),
    nil.

trap_set(Trap, Submission) ->
    traps_table(),
    true = ets:insert(oj_traps, {Trap, Submission}),
    nil.

trap_clear(Trap) ->
    traps_table(),
    true = ets:delete(oj_traps, Trap),
    nil.

traps() ->
    case ets:whereis(oj_traps) of
        undefined -> [];
        _ -> lists:sort(ets:tab2list(oj_traps))
    end.

traps_table() ->
    case ets:whereis(oj_traps) of
        undefined -> catch ets:new(oj_traps, [named_table, public, set]);
        _ -> ok
    end.

sh(Command) ->
    list_to_binary(os:cmd(binary_to_list(Command))).

mkdir(Path) ->
    ok = filelib:ensure_dir(binary_to_list(<<Path/binary, "/.">>)),
    nil.

getenv(Name, Default) ->
    case os:getenv(binary_to_list(Name)) of
        false -> Default;
        Value -> list_to_binary(Value)
    end.

now_ms() ->
    erlang:system_time(millisecond).

stderr(Bin) ->
    io:put_chars(standard_error, Bin),
    nil.

os_pid() ->
    list_to_binary(os:getpid()).

argv() ->
    [list_to_binary(A) || A <- init:get_plain_arguments()].

listen(Port) ->
    {ok, Socket} = gen_tcp:listen(Port, [binary,
                                         {packet, line},
                                         {active, false},
                                         {reuseaddr, true},
                                         {ip, {127, 0, 0, 1}}]),
    Socket.

accept(Listener) ->
    {ok, Socket} = gen_tcp:accept(Listener),
    Socket.

recv(Socket) ->
    case gen_tcp:recv(Socket, 0) of
        {ok, Bin} -> {ok, string:trim(Bin)};
        {error, _} -> {error, nil}
    end.

tcp_send(Socket, Bin) ->
    _ = gen_tcp:send(Socket, Bin),
    nil.

tcp_close(Socket) ->
    _ = gen_tcp:close(Socket),
    nil.
