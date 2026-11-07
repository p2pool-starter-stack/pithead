# shellcheck shell=bash
bench_api_state() {
    {
        declare -p IT_DASHBOARD_USER IT_DASHBOARD_PASSWORD 2>/dev/null || true
        cat "$HERE/lib/dashboard-guest-session.sh"
        cat <<'REQUEST'
stack_dir=$(docker inspect dashboard --format '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}') || exit 1
cd -- "$stack_dir" || exit 1
dashboard_guest_get http://127.0.0.1:8000/api/state 8
REQUEST
    } | on_bench 'bash -s'
}
