package main

import (
	"archive/tar"
	"bytes"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"io"
	"os"
)

// The long path exercises USTAR's prefix field with a real Go producer.
const input = "tests/abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrst/input.txt"

func main() {
	if len(os.Args) < 2 || len(os.Args) > 3 || (len(os.Args) == 3 && os.Args[2] != "verify" && os.Args[2] != "lua" && os.Args[2] != "lua-unsupported") {
		fmt.Fprintln(os.Stderr, "usage: bundle-fixture <output.tar> [verify|lua|lua-unsupported]")
		os.Exit(2)
	}
	var runnerAPI int
	if len(os.Args) == 3 {
		switch os.Args[2] {
		case "lua":
			runnerAPI = 1
		case "lua-unsupported":
			runnerAPI = 2
		}
	}
	if err := writeFixture(os.Args[1], runnerAPI); err != nil {
		panic(err)
	}
	if len(os.Args) > 2 && os.Args[2] == "verify" {
		if err := verifyFixture(os.Args[1]); err != nil {
			panic(err)
		}
	}
}

func verifyFixture(path string) error {
	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	if len(data) != 3072 || len(data)%512 != 0 {
		return fmt.Errorf("unexpected archive length: %d", len(data))
	}
	if fmt.Sprintf("%x", sha256.Sum256(data)) != "a94153c65bf4d0796ce75868d1c0db310ca86f5c9f26162d2d9251bdc4cd73db" {
		return fmt.Errorf("archive differs from the v1 golden digest")
	}
	reader := tar.NewReader(bytes.NewReader(data))
	for _, expected := range []string{"manifest.json", input} {
		header, err := reader.Next()
		if err != nil {
			return err
		}
		if header.Name != expected || header.Typeflag != tar.TypeReg || header.Format != tar.FormatUSTAR {
			return fmt.Errorf("unexpected USTAR entry: %#v", header)
		}
		if _, err := io.Copy(io.Discard, reader); err != nil {
			return err
		}
	}
	if _, err := reader.Next(); err != io.EOF {
		return fmt.Errorf("expected end of archive, got %v", err)
	}
	return nil
}

func writeFixture(path string, runnerAPI int) error {
	name, body := input, "42\n"
	fields := map[string]any{
		"format_version":           1,
		"execution_format":         "standard",
		"execution_format_version": 1,
	}
	if runnerAPI != 0 {
		name, body = "runner.lua", "return 0\n"
		fields["execution_format"] = "scripted_lua"
		fields["runner_api_version"] = runnerAPI
	}
	fields["files"] = []map[string]any{{"path": name, "size": len(body), "sha256": fmt.Sprintf("%x", sha256.Sum256([]byte(body)))}}
	manifest, err := json.Marshal(fields)
	if err != nil {
		return err
	}
	file, err := os.Create(path)
	if err != nil {
		return err
	}
	defer file.Close()
	archive := tar.NewWriter(file)
	for _, entry := range []struct{ name, data string }{{"manifest.json", string(manifest)}, {name, body}} {
		if err := archive.WriteHeader(&tar.Header{
			Name: entry.name, Size: int64(len(entry.data)), Mode: 0600, Typeflag: tar.TypeReg, Format: tar.FormatUSTAR,
		}); err != nil {
			return err
		}
		if _, err := archive.Write([]byte(entry.data)); err != nil {
			return err
		}
	}
	return archive.Close()
}
