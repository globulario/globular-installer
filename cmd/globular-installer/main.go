package main

import "os"

func main() {
	os.Exit(run(os.Args))
}

func run(args []string) int {
	_ = args
	return 0
}

func usage() {}
