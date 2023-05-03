-module(esmpplib).

-include("esmpplib.hrl").

-export([
    start/0,
    start/1,
    stop/0,

    start_pool/2,
    stop_pool/1,
    restart_pool/1,
    pool_connection_pids/1,

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

-spec start_pool(atom(), [term()]) ->
    ok | {error, reason()}.

start_pool(PoolName, PoolConfig) ->
    PoolSize = esmpplib_utils:lookup(size, PoolConfig, 1),
    ConnectionOptions0 = maps:from_list(esmpplib_utils:lookup(connection_options, PoolConfig)),
    ConnectionOptions = maps:put(id, PoolName, ConnectionOptions0),

    erlpool:start_pool(PoolName, [
        {size, PoolSize},
        {supervisor_shutdown, 10000},
        {group, esmpplib_connection_pool},
        {start_mfa, {esmpplib_connection, start_link, [ConnectionOptions]}}
    ]).

-spec stop_pool(atom()) ->
    ok | {error, reason()}.

stop_pool(PoolName) ->
    erlpool:stop_pool(PoolName).

-spec restart_pool(atom()) ->
    ok | {error, reason()}.

restart_pool(PoolName) ->
    erlpool:restart_pool(PoolName).

-spec submit_sm(atom(), binary(), binary(), binary()) ->
    {ok, MessageId::binary(), Parts::non_neg_integer()} | {error, reason()}.

-spec pool_connection_pids(atom()) ->
    [pid()] | {error, any()}.

pool_connection_pids(PoolName) ->
    erlpool:map(PoolName, fun(P) -> P end).

submit_sm(PoolName, SrcAddr, DstAddr, Message) ->
    Pid = erlpool:pid(PoolName),
    esmpplib_connection:submit_sm(Pid, SrcAddr, DstAddr, Message).

-spec submit_sm_async(atom(), any(), binary(), binary(), binary()) ->
    ok | {error, reason()}.

submit_sm_async(PoolName, MessageRef, SrcAddr, DstAddr, Message) ->
    Pid = erlpool:pid(PoolName),
    esmpplib_connection:submit_sm_async(Pid, MessageRef, SrcAddr, DstAddr, Message).

-spec query_sm(atom(), binary()) ->
    {ok, Resp::[{atom(), any()}]} | {error, reason()}.

query_sm(PoolName, MessageId) ->
    Pid = erlpool:pid(PoolName),
    esmpplib_connection:query_sm(Pid, MessageId).

-spec query_sm_async(atom(), binary()) ->
    ok | {error, reason()}.

query_sm_async(PoolName, MessageId) ->
    Pid = erlpool:pid(PoolName),
    esmpplib_connection:query_sm_async(Pid, MessageId).
