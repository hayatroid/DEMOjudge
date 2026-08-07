-module(oj_sandbox).

-export([absolute/1, which/1, is_dir/1, is_file/1, reset/1, copy/2,
         case_ids/1, jail/3]).

absolute(Path) ->
    list_to_binary(filename:absname(binary_to_list(Path))).

which(Name) ->
    case os:find_executable(binary_to_list(Name)) of
        false -> {error, nil};
        Path -> {ok, list_to_binary(Path)}
    end.

is_dir(Path) ->
    filelib:is_dir(binary_to_list(Path)).

is_file(Path) ->
    filelib:is_regular(binary_to_list(Path)).

reset(Dir) ->
    D = binary_to_list(Dir),
    _ = file:del_dir_r(D),
    ok = filelib:ensure_dir(D ++ "/."),
    nil.

copy(Src, Dst) ->
    case file:copy(binary_to_list(Src), binary_to_list(Dst)) of
        {ok, _} -> true;
        {error, _} -> false
    end.

case_ids(Dir) ->
    case file:list_dir(binary_to_list(Dir)) of
        {ok, Names} ->
            [list_to_binary(Id) || Id <- lists:usort([filename:rootname(N)
                                                      || N <- Names,
                                                         lists:member(filename:extension(N),
                                                                      [".in", ".out"])])];
        {error, _} ->
            []
    end.

jail(Exe, Args, TimeoutMs) ->
    Port = open_port({spawn_executable, binary_to_list(Exe)},
                     [{args, [binary_to_list(A) || A <- Args]},
                      exit_status, binary, in, hide]),
    gather(Port, <<>>, TimeoutMs).

gather(Port, Acc, TimeoutMs) ->
    receive
        {Port, {data, Bin}} ->
            gather(Port, <<Acc/binary, Bin/binary>>, TimeoutMs);
        {Port, {exit_status, _}} ->
            {ok, Acc}
    after TimeoutMs ->
        catch erlang:port_close(Port),
        {error, nil}
    end.
