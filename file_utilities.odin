package file_utilities

import "core:bytes"
import "core:io"
import "core:log"
import "core:os"
import "core:testing"

ReadFileError :: union {
	ReadDone,
	OpenError,
	io.Error,
	ReaderCreationError,
}

OpenError :: struct {
	filename: string,
	error:    os.Errno,
}

ReadDone :: struct {}

LineIterator :: struct {
	reader:         io.Reader,
	buffer:         []byte,
	position:       int,
	last_read_size: int,
}

ReaderCreationError :: struct {
	filename: string,
	stream:   io.Stream,
}

line_iterator_init :: proc(
	filename: string,
	buffer: []byte,
) -> (
	line_iterator: LineIterator,
	error: ReadFileError,
) {
	handle, open_error := os.open(filename, os.O_RDONLY)
	if open_error != os.ERROR_NONE {
		return LineIterator{}, OpenError{filename, open_error}
	}
	stream := os.stream_from_handle(handle)
	file_reader, ok := io.to_reader(stream)
	if !ok {
		return LineIterator{}, ReaderCreationError{filename, stream}
	}
	line_iterator.reader = file_reader
	line_iterator.position = len(buffer)
	line_iterator.buffer = buffer
	line_iterator.last_read_size = -1

	return line_iterator, nil
}

line_iterator_next :: proc(it: ^LineIterator) -> (line: []byte, error: ReadFileError) {
	assert(it.position <= len(it.buffer), "Position in `LineIterator` out of bounds")

	if it.last_read_size == 0 {
		return nil, ReadDone{}
	}

	if it.position == len(it.buffer) {
		bytes_read := io.read_full(it.reader, it.buffer) or_return
		it.position = 0
		it.last_read_size = bytes_read
	}

	// Find our next newline marker
	newline_index := bytes.index_any(it.buffer[it.position:], []byte{'\r', '\n'})
	if newline_index == -1 {
		// TODO: handle the case where we have a partial line at the end of our buffer
		log.debugf("No line found")
	} else {
		// we have a newline marker in our buffer so we can return a slice into the buffer
		line = it.buffer[it.position:newline_index]
		it.position = newline_index
		log.debugf("Found line: %s", string(line))

		return line, nil
	}

	return line, nil
}

@(test, private = "package")
test_line_by_lite_iterator :: proc(t: ^testing.T) {
	context.logger = log.create_console_logger()

	buffer: [8]byte
	it, init_error := line_iterator_init("odinfmt.json", buffer[:])
	testing.expect_value(t, init_error, nil)

	line, read_error := line_iterator_next(&it)
	testing.expect_value(t, read_error, nil)
	testing.expect_value(t, string(line), "{")
}
