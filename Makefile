ROOT_TEST=_build/test/lib

ifndef suite
	SUITE_EXEC=
else
	SUITE_EXEC=-suite $(suite)_SUITE
endif

ct:
	mkdir -p log
	rebar3 ct --compile_only
	ct_run  -no_auto_compile \
			-cover test/cover.spec \
			-dir $(ROOT_TEST)/esmpplib/test $(SUITE_EXEC) \
			-pa $(ROOT_TEST)/*/ebin \
			-pa $(ROOT_TEST)/*/test \
			-logdir log \
			-erl_args -config test/sys.config

