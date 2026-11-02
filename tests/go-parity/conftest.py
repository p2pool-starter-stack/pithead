import os

import pytest


@pytest.fixture(autouse=True)
def isolated_child_package(request, monkeypatch):
    if request.node.name != "test_default_runtime_bootstraps_and_reaps_python_child":
        return
    startup = request.getfixturevalue("tmp_path") / "python-startup"
    startup.mkdir()
    (startup / "sitecustomize.py").write_text(
        "import sys\n"
        "sys.meta_path[:] = [finder for finder in sys.meta_path "
        "if not finder.__module__.startswith('__editable___mining_dashboard_')]\n"
    )
    inherited = os.environ.get("PYTHONPATH", "")
    monkeypatch.setenv("PYTHONPATH", os.pathsep.join(filter(None, (str(startup), inherited))))
