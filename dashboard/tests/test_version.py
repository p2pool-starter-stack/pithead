
from mining_dashboard.version import resolve_version


class TestRelease:
    def test_version_with_no_git_metadata_is_a_release(self):
        info = resolve_version({"PITHEAD_VERSION": "1.3.0"})
        assert info == {"text": "v1.3.0", "title": "Pithead release v1.3.0", "dev": False}

    def test_leading_v_in_version_is_not_doubled(self):
        assert resolve_version({"PITHEAD_VERSION": "v2.0.1"})["text"] == "v2.0.1"

    def test_explicit_release_flag_wins_over_git_metadata(self):
        info = resolve_version(
            {
                "PITHEAD_VERSION": "1.3.0",
                "PITHEAD_RELEASE": "1",
                "PITHEAD_GIT_BRANCH": "main",
                "PITHEAD_GIT_COMMIT": "a1b2c3d",
            }
        )
        assert info["text"] == "v1.3.0"
        assert info["dev"] is False

    def test_release_flag_accepts_common_truthy_spellings(self):
        for val in ("1", "true", "TRUE", "yes", "on"):
            assert (
                resolve_version(
                    {
                        "PITHEAD_VERSION": "1.0.0",
                        "PITHEAD_RELEASE": val,
                        "PITHEAD_GIT_COMMIT": "deadbee",
                    }
                )["dev"]
                is False
            )


class TestDev:
    def test_branch_and_commit(self):
        info = resolve_version(
            {
                "PITHEAD_VERSION": "1.3.0",
                "PITHEAD_GIT_BRANCH": "feature/x",
                "PITHEAD_GIT_COMMIT": "a1b2c3d",
            }
        )
        assert info["text"] == "dev@a1b2c3d"
        assert info["dev"] is True
        assert "feature/x" in info["title"]
        assert "footer_commit" not in info

    def test_branch_and_commit_with_full_hash(self):
        info = resolve_version(
            {
                "PITHEAD_GIT_BRANCH": "main",
                "PITHEAD_GIT_COMMIT": "a1b2c3d",
                "PITHEAD_GIT_COMMIT_FULL": "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2",
                "PITHEAD_BUILD_TIME": "2025-01-15T10:30:00Z",
                "PITHEAD_BUILD_KIND": "DIY source",
            }
        )
        assert info["text"] == "dev@a1b2c3d"
        assert info["dev"] is True
        assert info["footer_commit"] == "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"
        assert info["footer_build_time"] == "2025-01-15T10:30:00Z"
        assert info["footer_kind"] == "DIY source"
        assert "footer_slot" not in info

    def test_dirty_marker_passes_through(self):
        info = resolve_version(
            {"PITHEAD_GIT_BRANCH": "main", "PITHEAD_GIT_COMMIT": "a1b2c3d-dirty"}
        )
        assert info["text"] == "dev@a1b2c3d-dirty"
        assert info["dev"] is True

    def test_a_versioned_build_with_a_commit_is_still_dev(self):
        info = resolve_version({"PITHEAD_VERSION": "1.3.0", "PITHEAD_GIT_COMMIT": "a1b2c3d"})
        assert info["dev"] is True
        assert info["text"] == "dev@a1b2c3d"

    def test_no_metadata_falls_back_to_generic_dev(self):
        info = resolve_version({})
        assert info == {"text": "dev build", "title": "Dev build", "dev": True}

    def test_blank_values_treated_as_absent(self):
        info = resolve_version(
            {"PITHEAD_VERSION": "  ", "PITHEAD_GIT_BRANCH": "", "PITHEAD_GIT_COMMIT": "  "}
        )
        assert info["text"] == "dev build"

    def test_appliance_footer_slot(self):
        info = resolve_version(
            {
                "PITHEAD_GIT_COMMIT": "deadbeef",
                "PITHEAD_GIT_COMMIT_FULL": "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef",
                "PITHEAD_BUILD_KIND": "appliance debug",
                "PITHEAD_BUILD_SLOT": "B",
            }
        )
        assert info["text"] == "dev@deadbeef"
        assert info["dev"] is True
        assert info["footer_kind"] == "appliance debug"
        assert info["footer_slot"] == "B"

    def test_footer_omitted_when_no_full_hash(self):
        info = resolve_version(
            {
                "PITHEAD_GIT_COMMIT": "a1b2c3d",
                "PITHEAD_GIT_COMMIT_FULL": "",
                "PITHEAD_BUILD_TIME": "",
                "PITHEAD_BUILD_KIND": "",
            }
        )
        assert info["text"] == "dev@a1b2c3d"
        for key in ("footer_commit", "footer_build_time", "footer_kind", "footer_slot"):
            assert key not in info
