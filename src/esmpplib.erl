-module(esmpplib).

-include("esmpplib.hrl").

-export([
    start/0,
    start/1,
    stop/0,
    restart_pool/1,

    submit_sm/4,
    submit_sm_async/5,
    query_sm/2,
    query_sm_async/2
]).

-spec start() ->
    ok | {error, reason()}.

start() ->
    start(temporary).

-spec start(permanent | transient | temporary) ->
    ok | {error, reason()}.

start(Type) ->
    case application:ensure_all_started(esmpplib, Type) of
        {ok, _} ->
            ok;
        Other ->
            Other
    end.

-spec stop() ->
    ok.

stop() ->
    application:stop(esmpplib).

-spec restart_pool(atom()) ->
    ok | {error, reason()}.

restart_pool(PoolName) ->
    erlpool:restart_pool(PoolName).

-spec submit_sm(atom(), binary(), binary(), binary()) ->
    ok | {error, reason()}.

submit_sm(PoolName, SrcAddr, DstAddr, Message) ->
    Pid = erlpool:pid(PoolName),
    esmpplib_connection:submit_sm(Pid, SrcAddr, DstAddr, Message).

submit_sm_async(PoolName, MessageRef, SrcAddr, DstAddr, Message) ->
    Pid = erlpool:pid(PoolName),
    esmpplib_connection:submit_sm_async(Pid, MessageRef, SrcAddr, DstAddr, Message).

query_sm(PoolName, MessageId) ->
    Pid = erlpool:pid(PoolName),
    esmpplib_connection:query_sm(Pid, MessageId).

query_sm_async(PoolName, MessageId) ->
    Pid = erlpool:pid(PoolName),
    esmpplib_connection:query_sm_async(Pid, MessageId).
