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
