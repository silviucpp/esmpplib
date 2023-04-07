-module(esmpplib_utils).

-include_lib("esmpplib.hrl").

-export([
    get_env/1,
    get_env/2,
    lookup/2,
    lookup/3,
    safe_call/2,
    safe_call/3,
    safe_bin2int/3
]).

get_env(Key) ->
    get_env(Key, null).

get_env(Key, Default) ->
    case application:get_env(esmpplib, Key) of
        {ok, Value} ->
            Value;
        _ ->
            Default
    end.

lookup(Key, List) ->
    lookup(Key, List, null).

lookup(Key, List, Default) ->
    case lists:keyfind(Key, 1, List) of
        {Key, Result} when Result =/= null ->
            Result;
        _ ->
            Default
    end.

safe_call(Receiver, Message) ->
    safe_call(Receiver, Message, 5000).

safe_call(Receiver, Message, Timeout) ->
    try
        gen_server:call(Receiver, Message, Timeout)
    catch
        exit:{noproc, _} ->
            {error, not_started};
        _: Exception ->
            {error, Exception}
    end.

safe_bin2int(Tag, Bin, Default) ->
    case catch binary_to_integer(Bin) of
        V when is_integer(V) ->
            V;
        _ ->
            ?ERROR_MSG("safe_bin2int failed for -> tag: ~p bin: ~p", [Tag, Bin]),
            Default
    end.
