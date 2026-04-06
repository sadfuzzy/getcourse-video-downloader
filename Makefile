BINARY := getcourse-video-downloader

build:
	go build -o $(BINARY) getcourse-video-downloader.go

clean:
	rm -f $(BINARY)

.PHONY: build clean
