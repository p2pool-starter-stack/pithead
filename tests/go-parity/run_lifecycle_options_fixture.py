import unittest

import test_lifecycle_options
from run_hybrid_fixture import HybridFixtureResult


def main():
    suite = unittest.defaultTestLoader.loadTestsFromModule(test_lifecycle_options)
    result = unittest.TextTestRunner(resultclass=HybridFixtureResult).run(suite)
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    raise SystemExit(main())
