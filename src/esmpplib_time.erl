-module(esmpplib_time).

-export([
    now_msec/0,
    now_sec/0,
    now_date_time/0,
    datetime2ts/1,
    ts2datetime/1
]).

now_msec() ->
    tic:now_to_epoch_msecs().

now_sec() ->
    tic:now_to_epoch_secs().

now_date_time() ->
    tic:epoch_secs_to_datetime(now_sec()).

datetime2ts(DateTime) ->
    tic:datetime_to_epoch_secs(DateTime).

ts2datetime(Ts) ->
    tic:epoch_secs_to_datetime(Ts).
