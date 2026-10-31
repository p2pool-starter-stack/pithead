/^After=p2pool.service$/ { after++; next }
/^Wants=p2pool.service$/ { wants++; next }
/^(After|Wants|Requires)=/ { invalid++; next }
/^IP=/ { ip++; next }
/^ContainerName=/ { names++; print "ContainerName=" name; next }
/^Image=/ { images++; print "Image=" image; next }
/^Network=mining.network$/ { networks++; print "Network=none"; next }
/^Network=/ { invalid++; next }
/^Volume=.*:\/tls:ro$/ { mounts++; next }
/^Volume=/ { invalid++; next }
/^PublishPort=/ { ports++; next }
/^\[(Unit|Container|Service|Install)\]$/ { print; next }
/^Description=pithead xmrig-proxy$/ { print; next }
/^(Environment|Exec|HealthCmd|HealthInterval|HealthTimeout|HealthRetries|HealthStartPeriod)=/ { print; next }
/^Tmpfs=\/(tmp|home\/ubuntu):size=64m,mode=1777$/ { print; next }
/^(ReadOnly=true|DropCapability=all|NoNewPrivileges=true|PodmanArgs=--memory 512m --memory-swap 512m)$/ { print; next }
/^(Notify=healthy|Restart=always|TimeoutStartSec=infinity|WantedBy=multi-user.target)$/ { print; next }
{ invalid++ }
END {
    if (invalid || after != 1 || wants != 1 || ip != 1 || names != 1 ||
        images != 1 || networks != 1 || mounts != 1 || ports != 1) {
        print "native Quadlet proxy resource rewrite refused renderer drift" > "/dev/stderr"
        exit 1
    }
}
