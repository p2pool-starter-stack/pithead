import unittest

import test_env_write
from run_hybrid_fixture import HybridFixtureResult

suite = unittest.defaultTestLoader.loadTestsFromModule(test_env_write)
result = unittest.TextTestRunner(resultclass=HybridFixtureResult).run(suite)
raise SystemExit(0 if result.wasSuccessful() else 1)
