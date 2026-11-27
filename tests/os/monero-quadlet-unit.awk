# Refuse renderer drift instead of accidentally retaining a live data mount or dependency.
/^After=tor.service$/ { after++; next }
/^Requires=tor.service$/ { requires++; next }
/^(After|Requires)=/ { invalid++; next }
/^IP=/ { ip++; next }
/^ContainerName=/ { container++; print "ContainerName=" name; next }
/^Image=/ { images++; print "Image=" image; next }
/^Network=/ { networks++; print "Network=" network; next }
/^Volume=.*:\/home\/ubuntu\/\.bitmonero$/ {
    mounts++; print "Volume=" data ":/home/ubuntu/.bitmonero"; next
}
/^Volume=.*:\/home\/ubuntu\/bitmonero.conf.template:ro$/ {
    templates++; print "Volume=" template ":/home/ubuntu/bitmonero.conf.template:ro"; next
}
/^PublishPort=.*:18081:18081$/ { rpc++; print "PublishPort=127.0.0.1:38081:18081"; next }
/^PublishPort=.*:18083:18083$/ { zmq++; print "PublishPort=127.0.0.1:38083:18083"; next }
/^PublishPort=/ { invalid++; next }
{ print }
END {
    if (invalid || after != 1 || requires != 1 || ip != 1 || container != 1 ||
        images != 1 || networks != 1 || mounts != 1 || templates != 1 || rpc != 1 || zmq != 1) {
        print "native Quadlet fixture resource rewrite refused renderer drift" > "/dev/stderr"
        exit 1
    }
}
