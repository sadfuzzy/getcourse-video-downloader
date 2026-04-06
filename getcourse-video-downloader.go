package main

import (
	"bufio"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
)

var wg sync.WaitGroup
var semaphore chan struct{}

func main() {
	fmt.Println("Start.")
	if len(os.Args) != 3 {
		printHelp()
		os.Exit(1)
	}

	URL := os.Args[1]
	resultFile := os.Args[2]
	touchFile(resultFile)

	threads := 4 // Default to 4 threads
	if pp := os.Getenv("PP"); pp != "" {
		if p, err := strconv.Atoi(pp); err == nil && p > 0 {
			threads = p
		}
	}
	semaphore = make(chan struct{}, threads)

	tmpdir, err := os.MkdirTemp("", "getcourse")
	if err != nil {
		fmt.Println("Error creating temporary directory:", err)
		os.Exit(1)
	}
	defer os.RemoveAll(tmpdir)

	mainPlaylist, err := downloadTempFile(URL)
	if err != nil {
		fmt.Println("Error downloading main playlist:", err)
		os.Exit(1)
	}
	defer os.Remove(mainPlaylist)

	secondPlaylist, err := os.CreateTemp("", "playlist")
	if err != nil {
		fmt.Println("Error creating temporary file for second playlist:", err)
		os.Exit(1)
	}
	secondPlaylist.Close()
	defer os.Remove(secondPlaylist.Name())

	if hasVideoSegments(mainPlaylist) {
		if err = copyFile(mainPlaylist, secondPlaylist.Name()); err != nil {
			fmt.Println("Error copying playlist:", err)
			os.Exit(1)
		}
	} else {
		tail, err := getTailLine(mainPlaylist)
		if err != nil || !strings.HasPrefix(tail, "https") {
			fmt.Println("No valid segments or playlist found.")
			os.Exit(1)
		}
		err = downloadToFile(tail, secondPlaylist.Name())
		if err != nil {
			fmt.Println("Error downloading secondary playlist:", err)
			os.Exit(1)
		}
	}

	downloadSegments(secondPlaylist.Name(), tmpdir)

	err = concatenateFiles(tmpdir, resultFile)
	if err != nil {
		fmt.Println("Error concatenating video segments:", err)
		os.Exit(1)
	}

	fmt.Printf("Download complete. Result saved to: %s\n", resultFile)
}

func printHelp() {
	fmt.Printf(`
Первым аргументом должна быть ссылка на плей-лист, найденная в исходном коде страницы сайта GetCourse.
Пример: <video id="vgc-player_html5_api" data-master="нужная ссылка" ... />.
Вторым аргументом должен быть путь к файлу для сохранения скачанного видео, рекомендуемое расширение — ts.
Пример: "Как скачать видео с GetCourse.ts"
Скопируйте ссылку и запустите скрипт, например, так:
%s "эта_ссылка" "Как скачать видео с GetCourse.ts"
Инструкция с графическими иллюстрациями здесь: https://github.com/mikhailnov/getcourse-video-downloader
О проблемах в работе сообщайте сюда: https://github.com/mikhailnov/getcourse-video-downloader/issues
`, os.Args[0])
}

func touchFile(filename string) {
	f, err := os.Create(filename)
	if err != nil {
		fmt.Println("Error creating file:", err)
		os.Exit(1)
	}
	f.Close()
}

func downloadTempFile(URL string) (string, error) {
	tmpFile, err := os.CreateTemp("", "main_playlist")
	if err != nil {
		return "", err
	}
	tmpFile.Close()

	err = downloadToFile(URL, tmpFile.Name())
	if err != nil {
		os.Remove(tmpFile.Name())
		return "", err
	}

	return tmpFile.Name(), nil
}

func downloadToFile(URL, path string) error {
	resp, err := http.Get(URL)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("HTTP %d for %s", resp.StatusCode, URL)
	}

	out, err := os.Create(path)
	if err != nil {
		return err
	}
	defer out.Close()

	_, err = io.Copy(out, resp.Body)
	return err
}

func hasVideoSegments(filepath string) bool {
	file, err := os.Open(filepath)
	if err != nil {
		return false
	}
	defer file.Close()

	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		line := scanner.Text()
		if strings.HasPrefix(line, "http") {
			lower := strings.ToLower(line)
			base := lower
			if i := strings.Index(lower, "?"); i != -1 {
				base = lower[:i]
			}
			if strings.HasSuffix(base, ".ts") || strings.HasSuffix(base, ".bin") {
				return true
			}
		}
	}
	return false
}

func getTailLine(filepath string) (string, error) {
	file, err := os.Open(filepath)
	if err != nil {
		return "", err
	}
	defer file.Close()

	var lastLine string
	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		lastLine = scanner.Text()
	}
	return lastLine, scanner.Err()
}

func copyFile(src, dst string) error {
	input, err := os.ReadFile(src)
	if err != nil {
		return err
	}
	return os.WriteFile(dst, input, 0644)
}

func downloadSegments(playlistPath, tmpdir string) {
	file, err := os.Open(playlistPath)
	if err != nil {
		fmt.Println("Error opening playlist file:", err)
		os.Exit(1)
	}
	defer file.Close()

	scanner := bufio.NewScanner(file)
	c := 0

	for scanner.Scan() {
		line := scanner.Text()
		if !strings.HasPrefix(line, "http") {
			continue
		}
		wg.Add(1)
		semaphore <- struct{}{}
		go downloadSegment(line, tmpdir, c)
		c++
	}
	wg.Wait()
}

func downloadSegment(url, tmpdir string, index int) {
	defer wg.Done()
	defer func() { <-semaphore }()

	outputPath := filepath.Join(tmpdir, fmt.Sprintf("%05d.ts", index))
	const maxRetries = 12
	var err error
	for i := 0; i < maxRetries; i++ {
		err = downloadToFile(url, outputPath)
		if err == nil {
			return
		}
		fmt.Printf("Segment %d attempt %d failed: %v\n", index, i+1, err)
	}
	fmt.Printf("Error downloading segment %d after %d retries: %v\n", index, maxRetries, err)
}

func concatenateFiles(dir, outputFile string) error {
	files, err := filepath.Glob(filepath.Join(dir, "*.ts"))
	if err != nil {
		return err
	}

	out, err := os.Create(outputFile)
	if err != nil {
		return err
	}
	defer out.Close()

	for _, file := range files {
		in, err := os.Open(file)
		if err != nil {
			return err
		}
		_, err = io.Copy(out, in)
		in.Close()
		if err != nil {
			return err
		}
	}

	return nil
}

// export PP=6
// go run getcourse-video-downloader.go "playlist_url" "output_file.ts"
