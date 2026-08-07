-module(oj_web).

%% The accept loop and the request parsing come from the emulator: {packet,
%% http_bin} is the OTP HTTP tokeniser.

-export([listen/1, serve/2, request/1, write/2]).

listen(Port) ->
    {ok, Socket} = gen_tcp:listen(Port, [binary,
                                         {packet, http_bin},
                                         {active, false},
                                         {reuseaddr, true},
                                         {backlog, 64}]),
    Socket.

%% A reader that does not own its socket gets `not_owner' rather than data, so
%% serve hands the socket over before the process runs.
serve(Listener, Handler) ->
    {ok, Socket} = gen_tcp:accept(Listener),
    Pid = spawn(fun() -> receive go -> Handler(Socket) end end),
    ok = gen_tcp:controlling_process(Socket, Pid),
    Pid ! go,
    serve(Listener, Handler).

request(Socket) ->
    ok = inet:setopts(Socket, [{packet, http_bin}]),
    case gen_tcp:recv(Socket, 0, 20000) of
        {ok, {http_request, Method, {abs_path, Target}, _}} ->
            case headers(Socket, 0, <<>>, <<>>, <<>>) of
                {ok, Length, Token, Cookie, Kind} ->
                    {ok, {method(Method), Target, present(Token, Cookie), Kind,
                          body(Socket, Length)}};
                error ->
                    {error, nil}
            end;
        _ ->
            {error, nil}
    end.

headers(Socket, Length, Token, Cookie, Kind) ->
    case gen_tcp:recv(Socket, 0, 20000) of
        {ok, http_eoh} ->
            {ok, Length, Token, Cookie, Kind};
        {ok, {http_header, _, Name, _, Value}} ->
            case string:lowercase(field(Name)) of
                <<"content-length">> ->
                    headers(Socket, binary_to_integer(Value), Token, Cookie, Kind);
                <<"x-oj-token">> ->
                    headers(Socket, Length, Value, Cookie, Kind);
                <<"cookie">> ->
                    headers(Socket, Length, Token, Value, Kind);
                <<"content-type">> ->
                    headers(Socket, Length, Token, Cookie, Value);
                _ ->
                    headers(Socket, Length, Token, Cookie, Kind)
            end;
        _ ->
            error
    end.

%% present prefers the header over the cookie, because curl carries the token and
%% the browser carries what /login set.
present(<<>>, Cookie) -> crumb(Cookie);
present(Token, _) -> Token.

crumb(Cookie) ->
    Crumbs = [string:trim(C) || C <- binary:split(Cookie, <<";">>, [global])],
    case [V || <<"oj_token=", V/binary>> <- Crumbs] of
        [Value | _] -> Value;
        [] -> <<>>
    end.

field(Name) when is_atom(Name) -> atom_to_binary(Name, utf8);
field(Name) when is_binary(Name) -> Name.

body(_Socket, 0) ->
    <<>>;
body(Socket, Length) ->
    ok = inet:setopts(Socket, [{packet, raw}]),
    case gen_tcp:recv(Socket, Length, 20000) of
        {ok, Bin} -> Bin;
        _ -> <<>>
    end.

method(Method) when is_atom(Method) -> atom_to_binary(Method, utf8);
method(Method) when is_binary(Method) -> Method.

write(Socket, Bin) ->
    case gen_tcp:send(Socket, Bin) of
        ok -> {ok, nil};
        {error, _} -> {error, nil}
    end.
