import importlib
import os
import unittest

FIXTURES = {
    "test_caddy": "test_marker_enables_native_helper",
    "test_lifecycle_options": "test_internal_marker_sends_arguments_only_on_stdin",
    "test_env_write": "test_internal_marker_selects_native_writer_with_bash_dispatch",
    "test_tari_secret": "test_internal_marker_selects_native_writer_with_bash_dispatch",
    "test_wallet_classifiers": "test_internal_marker_and_stdin_protocol_reach_go",
}


class HybridFixtureResult(unittest.TextTestResult):
    def startTest(self, test):
        os.environ.pop("_PITHEAD_GO_HYBRID", None)
        module, _case, method = test.id().rsplit(".", 2)
        if FIXTURES.get(module) == method:
            os.environ["_PITHEAD_GO_HYBRID"] = "1"
        super().startTest(test)

    def stopTest(self, test):
        os.environ.pop("_PITHEAD_GO_HYBRID", None)
        super().stopTest(test)


def main():
    suite = unittest.TestSuite()
    for name in FIXTURES:
        module = importlib.import_module(name)
        suite.addTests(unittest.defaultTestLoader.loadTestsFromModule(module))
    result = unittest.TextTestRunner(resultclass=HybridFixtureResult).run(suite)
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    raise SystemExit(main())
