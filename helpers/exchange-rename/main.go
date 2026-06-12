//go:build linux && amd64

package main

import (
	"fmt"
	"os"
	"syscall"
	"unsafe"
)

const (
	// amd64 syscall number, kept safe by the linux && amd64 build tag above.
	SYS_RENAMEAT2   = 316
	RENAME_EXCHANGE = 0x2
	// AT_FDCWD is -100. Syscall arguments are uintptr, so encode it as
	// two's-complement uintptr instead of passing a signed integer.
	AT_FDCWD = ^uintptr(99)
)

func main() {
	if len(os.Args) != 3 {
		fmt.Fprintln(os.Stderr, "usage: exchange-rename OLD_PATH NEW_PATH")
		os.Exit(64)
	}

	oldPath, err := syscall.BytePtrFromString(os.Args[1])
	if err != nil {
		fmt.Fprintf(os.Stderr, "exchange-rename: invalid old path: %v\n", err)
		os.Exit(64)
	}
	newPath, err := syscall.BytePtrFromString(os.Args[2])
	if err != nil {
		fmt.Fprintf(os.Stderr, "exchange-rename: invalid new path: %v\n", err)
		os.Exit(64)
	}

	_, _, errno := syscall.Syscall6(
		SYS_RENAMEAT2,
		AT_FDCWD,
		uintptr(unsafe.Pointer(oldPath)),
		AT_FDCWD,
		uintptr(unsafe.Pointer(newPath)),
		uintptr(RENAME_EXCHANGE),
		0,
	)
	if errno != 0 {
		fmt.Fprintf(os.Stderr, "exchange-rename: renameat2 RENAME_EXCHANGE failed: %v\n", errno)
		os.Exit(1)
	}
}
