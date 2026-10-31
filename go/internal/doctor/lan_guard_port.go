package doctor

import (
	"bytes"
	"os"
	"os/exec"
)

func lanPortExposed(container, port string) (bool, error) {
	docker, err := networkTool("docker")
	if err != nil || docker == "" {
		return false, err
	}
	grep, err := networkTool("grep")
	if err != nil || grep == "" {
		return false, ErrUnsupportedProbeInput
	}
	read, write, err := os.Pipe()
	if err != nil {
		return false, ErrUnsupportedProbeInput
	}
	defer read.Close()
	defer write.Close()
	producer := exec.Command(docker, "port", container, port+"/tcp")
	consumer := exec.Command(grep, "-qv", `^127\.0\.0\.1:`)
	producer.Stdout, consumer.Stdin = write, read
	var stdout, stderr bytes.Buffer
	consumer.Stdout, consumer.Stderr = &stdout, &stderr
	if err := consumer.Start(); err != nil {
		return false, ErrUnsupportedProbeInput
	}
	startErr := producer.Start()
	read.Close()
	write.Close()
	var producerErr error
	if startErr == nil {
		producerErr = producer.Wait()
	}
	consumerErr := consumer.Wait()
	if startErr != nil || unsupportedLaunch(producerErr) || unsupportedLaunch(consumerErr) || stdout.Len() != 0 || stderr.Len() != 0 {
		return false, ErrUnsupportedProbeInput
	}
	return producerErr == nil && consumerErr == nil, nil
}
