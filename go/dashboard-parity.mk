.PHONY: test-go-dashboard-wizard-policy-parity
test-go-dashboard-wizard-policy-parity: go-dashboard-build
	cd dashboard && PITHEAD_IMPL=go PYTHONPATH="$(CURDIR)/tests/go-parity:$(CURDIR)/dashboard" uv run --locked --extra test python -m pytest -p dashboard_wizard_terminal_plugin tests/web/test_wizard*.py tests/web/test_config_defaults.py "$(CURDIR)/tests/go-parity/dashboard_wizard_policy_compare.py" "$(CURDIR)/tests/go-parity/dashboard_wizard_policy_guards.py"
.PHONY: test-go-dashboard-channel-parity
.PHONY: test-go-dashboard-wizard-transaction-parity
test-go-dashboard-wizard-transaction-parity: go-dashboard-build
	cd dashboard && PITHEAD_IMPL=go PYTHONPATH="$(CURDIR)/tests/go-parity:$(CURDIR)/dashboard" uv run --locked --extra test python -m pytest -p dashboard_wizard_terminal_plugin tests/web/test_wizard*.py "$(CURDIR)/tests/go-parity/dashboard_wizard_transaction_compare.py" "$(CURDIR)/tests/go-parity/dashboard_wizard_transaction_guards.py" "$(CURDIR)/tests/go-parity/dashboard_wizard_writer_failures.py"
test-go-dashboard-channel-parity: go-dashboard-build
	cd dashboard && PITHEAD_IMPL=go PYTHONPATH="$(CURDIR)/tests/go-parity:$(CURDIR)/dashboard" uv run --locked --extra test python -m pytest -p dashboard_wizard_terminal_plugin tests/service/test_control_service.py tests/service/test_control_result_polling.py tests/service/test_request_spool.py tests/web/test_server_control_routes_enabled.py tests/web/test_server_control_routes_disabled.py tests/web/test_wizard*.py "$(CURDIR)/tests/go-parity/dashboard_channel_compare.py" "$(CURDIR)/tests/go-parity/dashboard_channel_startup.py" "$(CURDIR)/tests/go-parity/dashboard_channel_guards.py"

.PHONY: test-go-dashboard-wizard-config-parity
test-go-dashboard-wizard-config-parity: go-dashboard-build
	cd dashboard && PITHEAD_IMPL=go PYTHONPATH="$(CURDIR)/tests/go-parity:$(CURDIR)/dashboard" uv run --locked --extra test python -m pytest -p dashboard_wizard_terminal_plugin tests/web/test_wizard*.py tests/web/test_config_defaults.py tests/service/test_config_version.py "$(CURDIR)/tests/go-parity/dashboard_wizard_config_compare.py" "$(CURDIR)/tests/go-parity/dashboard_wizard_config_shapes.py" "$(CURDIR)/tests/go-parity/dashboard_wizard_config_guards.py"

.PHONY: test-go-dashboard-wizard-terminal-parity
test-go-dashboard-wizard-terminal-parity: go-dashboard-build
	cd dashboard && PITHEAD_IMPL=go PYTHONPATH="$(CURDIR)/tests/go-parity:$(CURDIR)/dashboard" uv run --locked --extra test python -m pytest -p dashboard_wizard_terminal_plugin tests/web/test_wizard*.py tests/web/test_config_defaults.py tests/service/test_config_version.py "$(CURDIR)/tests/go-parity/dashboard_wizard_terminal_compare.py" "$(CURDIR)/tests/go-parity/dashboard_wizard_terminal_concurrency.py" "$(CURDIR)/tests/go-parity/dashboard_wizard_terminal_guards.py"

.PHONY: test-go-dashboard-wizard-submission-parity
test-go-dashboard-wizard-submission-parity: go-dashboard-build
	cd dashboard && PITHEAD_IMPL=go PYTHONPATH="$(CURDIR)/tests/go-parity:$(CURDIR)/dashboard" uv run --locked --extra test python -m pytest -p dashboard_wizard_submission_plugin tests/web/test_wizard*.py tests/web/test_config_defaults.py tests/service/test_config_version.py "$(CURDIR)/tests/go-parity/dashboard_wizard_submission_compare.py" "$(CURDIR)/tests/go-parity/dashboard_wizard_submission_guards.py"

.PHONY: test-go-dashboard-wizard-typed-parity
test-go-dashboard-wizard-typed-parity: go-dashboard-build
	cd dashboard && PITHEAD_IMPL=go PYTHONPATH="$(CURDIR)/tests/go-parity:$(CURDIR)/dashboard" uv run --locked --extra test python -m pytest -p dashboard_wizard_typed_plugin tests/web/test_wizard*.py tests/web/test_config_defaults.py tests/service/test_config_version.py "$(CURDIR)/tests/go-parity/dashboard_wizard_typed_compare.py" "$(CURDIR)/tests/go-parity/dashboard_wizard_typed_guards.py"

.PHONY: test-go-dashboard-wizard-values-parity
test-go-dashboard-wizard-values-parity: go-dashboard-build
	cd dashboard && PITHEAD_IMPL=go PYTHONPATH="$(CURDIR)/tests/go-parity:$(CURDIR)/dashboard" uv run --locked --extra test python -m pytest -p dashboard_wizard_values_plugin tests/web/test_wizard*.py tests/web/test_config_defaults.py tests/service/test_config_version.py "$(CURDIR)/tests/go-parity/dashboard_wizard_values_compare.py" "$(CURDIR)/tests/go-parity/dashboard_wizard_values_guards.py"

.PHONY: test-go-dashboard-documents-parity
test-go-dashboard-documents-parity: go-dashboard-build
	cd dashboard && PITHEAD_IMPL=go PYTHONPATH="$(CURDIR)/tests/go-parity:$(CURDIR)/dashboard" uv run --locked --extra test python -m pytest -p dashboard_documents_plugin tests/config/test_documents.py tests/web/test_config_documents.py tests/web/test_config_commit.py tests/web/test_server_control_routes_enabled.py tests/web/test_server_control_routes_disabled.py tests/service/test_data_service_watch_host_config.py tests/web/test_wizard*.py tests/web/test_config_defaults.py tests/service/test_config_version.py "$(CURDIR)/tests/go-parity/dashboard_documents_compare.py" "$(CURDIR)/tests/go-parity/dashboard_documents_guards.py"

.PHONY: test-go-dashboard-control-http-parity
test-go-dashboard-control-http-parity: go-dashboard-build
	cd dashboard && PITHEAD_IMPL=go PYTHONPATH="$(CURDIR)/tests/go-parity:$(CURDIR)/dashboard" uv run --locked --extra test python -m pytest -p dashboard_control_http_plugin tests/web/test_server_control_routes_enabled.py tests/web/test_server_control_routes_disabled.py tests/web/test_config_commit.py tests/web/test_config_documents.py tests/web/test_worker_adopt_route.py tests/service/test_control_service.py tests/service/test_control_result_polling.py tests/service/test_request_spool.py "$(CURDIR)/tests/go-parity/dashboard_control_http_compare.py" "$(CURDIR)/tests/go-parity/dashboard_control_http_guards.py" "$(CURDIR)/tests/go-parity/dashboard_control_http_availability.py"

.PHONY: test-go-dashboard-wizard-preparation-parity
test-go-dashboard-wizard-preparation-parity: go-dashboard-build
	cd dashboard && PITHEAD_IMPL=go PYTHONPATH="$(CURDIR)/tests/go-parity:$(CURDIR)/dashboard" uv run --locked --extra test python -m pytest -p dashboard_wizard_preparation_plugin tests/web/test_wizard*.py tests/web/test_config_defaults.py tests/service/test_config_version.py "$(CURDIR)/tests/go-parity/dashboard_wizard_preparation_compare.py" "$(CURDIR)/tests/go-parity/dashboard_wizard_preparation_guards.py"

.PHONY: test-go-dashboard-wizard-state-parity
test-go-dashboard-wizard-state-parity: go-dashboard-build
	cd dashboard && PITHEAD_IMPL=go PYTHONPATH="$(CURDIR)/tests/go-parity:$(CURDIR)/dashboard" uv run --locked --extra test python -m pytest -p dashboard_wizard_state_plugin tests/web/test_wizard*.py tests/web/test_config_defaults.py tests/service/test_config_version.py "$(CURDIR)/tests/go-parity/dashboard_channel_compare.py::test_wizard_state_coalesces_and_keeps_auth_responsive" "$(CURDIR)/tests/go-parity/dashboard_wizard_state_compare.py" "$(CURDIR)/tests/go-parity/dashboard_wizard_state_guards.py"

.PHONY: test-go-dashboard-worker-http-parity
test-go-dashboard-worker-http-parity: go-dashboard-build
	cd dashboard && PITHEAD_IMPL=go PYTHONPATH="$(CURDIR)/tests/go-parity:$(CURDIR)/dashboard" uv run --locked --extra test python -m pytest -p dashboard_worker_http_plugin tests/web/test_server_worker*.py tests/web/test_worker_upgrade*.py tests/web/test_worker_detail_ip.py tests/service/test_control_service.py tests/service/test_request_spool.py tests/service/test_worker_config_credentials.py tests/service/workers/test_worker_refresh.py tests/client/test_rigforge_config.py "$(CURDIR)/tests/go-parity/dashboard_worker_http_compare.py" "$(CURDIR)/tests/go-parity/dashboard_worker_http_guards.py" "$(CURDIR)/tests/go-parity/dashboard_worker_http_failures.py"

.PHONY: test-go-shipping-parity
test-go-shipping-parity: go-build go-dashboard-build pithead
	cd dashboard && PITHEAD_IMPL=go PYTHONPATH="$(CURDIR)/tests/go-parity:$(CURDIR)/dashboard" uv run --locked --extra test python -m pytest "$(CURDIR)/tests/go-parity/test_go_shipping.py" "$(CURDIR)/tests/go-parity/test_go_shipping_builds.py"

.PHONY: test-go-dashboard-earnings-parity
test-go-dashboard-earnings-parity: go-dashboard-build
	cd dashboard && TZ=UTC PITHEAD_IMPL=go PYTHONPATH="$(CURDIR)/tests/go-parity:$(CURDIR)/dashboard" uv run --locked --extra test python -m pytest -p dashboard_earnings_plugin tests/service/xvb/test_earnings.py tests/service/xvb/test_numeric_properties.py tests/service/notify/test_telegram_commands_formatting.py tests/web/views/test_xvb_views_earnings*.py tests/web/test_server_state_api.py tests/web/views/test_views.py "$(CURDIR)/tests/go-parity/dashboard_earnings_compare.py" "$(CURDIR)/tests/go-parity/dashboard_earnings_guards.py" "$(CURDIR)/tests/go-parity/dashboard_earnings_bridge.py"

.PHONY: test-go-dashboard-forecast-parity
test-go-dashboard-forecast-parity: go-dashboard-build
	cd dashboard && TZ=UTC PITHEAD_IMPL=go PYTHONPATH="$(CURDIR)/tests/go-parity:$(CURDIR)/dashboard" uv run --locked --extra test python -m pytest -p dashboard_forecast_plugin tests/web/views/test_xvb_views_xvb*.py tests/web/test_server_state_api.py tests/web/views/test_views.py "$(CURDIR)/tests/go-parity/dashboard_forecast_compare.py" "$(CURDIR)/tests/go-parity/dashboard_forecast_guards.py" "$(CURDIR)/tests/go-parity/dashboard_forecast_bridge.py"

.PHONY: test-go-dashboard-worker-detail-parity
test-go-dashboard-worker-detail-parity: go-dashboard-build
	cd dashboard && TZ=UTC PITHEAD_IMPL=go PYTHONPATH="$(CURDIR)/tests/go-parity:$(CURDIR)/dashboard" uv run --locked --extra test python -m pytest -p dashboard_worker_detail_plugin tests/client/test_rig_config_meta.py tests/web/test_server_worker_inspect.py tests/web/test_worker_detail*.py tests/web/test_worker_config_drift.py tests/web/test_worker_agent_freshness.py tests/web/views/test_views.py "$(CURDIR)/tests/go-parity/dashboard_worker_detail_compare.py" "$(CURDIR)/tests/go-parity/dashboard_worker_detail_guards.py" "$(CURDIR)/tests/go-parity/dashboard_worker_detail_bridge.py" "$(CURDIR)/tests/go-parity/dashboard_worker_detail_runtime.py" "$(CURDIR)/tests/go-parity/dashboard_worker_detail_numeric.py"

.PHONY: test-go-dashboard-polling-parity
test-go-dashboard-polling-parity: go-dashboard-build
	cd dashboard && TZ=UTC PITHEAD_IMPL=go PYTHONPATH="$(CURDIR)/tests/go-parity:$(CURDIR)/dashboard" uv run --locked --extra test python -m pytest -p dashboard_polling_plugin tests/service/test_data_helpers.py tests/service/test_worker_probe.py tests/service/test_worker_proxy_liveness.py tests/service/test_data_service_*.py "$(CURDIR)/tests/go-parity/dashboard_polling_compare.py" "$(CURDIR)/tests/go-parity/dashboard_polling_guards.py" "$(CURDIR)/tests/go-parity/dashboard_polling_runtime.py"

.PHONY: test-go-dashboard-assembly-parity
test-go-dashboard-assembly-parity: go-dashboard-build
	cd dashboard && TZ=UTC PITHEAD_IMPL=go PYTHONPATH="$(CURDIR)/tests/go-parity:$(CURDIR)/dashboard" uv run --locked --extra test python -m pytest -p dashboard_assembly_plugin tests/web/views/test_*.py tests/web/test_server_state_api.py "$(CURDIR)/tests/go-parity/dashboard_assembly_compare.py" "$(CURDIR)/tests/go-parity/dashboard_assembly_guards.py" "$(CURDIR)/tests/go-parity/dashboard_assembly_runtime.py" "$(CURDIR)/tests/go-parity/dashboard_history_concurrent.py"

.PHONY: test-go-dashboard-rigforge-parity
test-go-dashboard-rigforge-parity: go-dashboard-build
	cd dashboard && TZ=UTC PITHEAD_IMPL=go PYTHONPATH="$(CURDIR)/tests/go-parity:$(CURDIR)/dashboard" uv run --locked --extra test python -m pytest -p dashboard_rigforge_plugin \
		tests/client/test_xmrig_client.py::test_parse_rigforge_full_block tests/client/test_rigforge_config.py::TestRigWritableConfig \
		tests/client/test_rigforge_config.py::test_parse_rigforge_absent_is_none tests/client/test_rigforge_config.py::test_parse_rigforge_miner_down_has_no_xmrig_keys tests/client/test_rigforge_config.py::test_parse_rigforge_all_null_fields \
		tests/client/test_rig_config_meta.py::test_parse_rigforge_carries_the_block_through tests/client/test_rig_config_meta.py::test_a_rig_without_the_block_carries_none tests/client/test_rigforge_freshness.py \
		tests/service/test_data_helpers.py::TestMergeDirectStats::test_rigforge_block_carried_onto_worker tests/service/workers/test_worker_refresh.py::TestRefreshWorkerAfterUpgrade tests/service/workers/test_worker_refresh.py::test_main_poll_cannot_overwrite_newer_targeted_report \
		"$(CURDIR)/tests/integration/fakes/test_contract.py::test_worker_auth_none_open_api_reads_and_parses" "$(CURDIR)/tests/integration/fakes/test_contract.py::test_worker_miner_down_body_parses_as_up_but_miner_down" \
		"$(CURDIR)/tests/integration/fakes/test_contract.py::test_worker_config_prefill_parses_over_the_wire" "$(CURDIR)/tests/integration/fakes/test_contract.py::test_worker_config_provenance_parses_over_the_wire" "$(CURDIR)/tests/integration/fakes/test_contract.py::test_a_rig_mid_change_or_fresh_reconciles_nothing" \
		"$(CURDIR)/tests/go-parity/dashboard_polling_compare.py::test_direct_stats_keeps_python_rigforge_parse" "$(CURDIR)/tests/go-parity/dashboard_rigforge_compare.py" "$(CURDIR)/tests/go-parity/dashboard_rigforge_guards.py" "$(CURDIR)/tests/go-parity/dashboard_rigforge_runtime.py"
