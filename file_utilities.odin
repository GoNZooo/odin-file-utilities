package file_utilities

import "core:bytes"
import "core:io"
import "core:log"
import "core:os"
import "core:testing"

ReadLineError :: union {
	BufferTooSmall,
	io.Error,
	ReadDone,
}

ReadFileError :: union {
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
	file_position:  i64,
	last_read_size: int,
}

ReaderCreationError :: struct {
	filename: string,
	stream:   io.Stream,
}

BufferTooSmall :: struct {
	size: int,
}

// Returns a `LineIterator` to be used with `line_iterator_next`. Note that the used buffer will
// change over time so the caller should copy returned lines that matter if they should be kept.
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

// Returns the next line in the iterator or `ReadDone` if there are no more lines to read. Note
// that the returned line is only valid until the next call to `line_iterator_next` and that the
// internal buffer changes over time, so the caller should copy the returned line if it should be
// kept.
line_iterator_next :: proc(it: ^LineIterator) -> (line: []byte, error: ReadLineError) {
	assert(it.position <= len(it.buffer), "Position in `LineIterator` out of bounds")

	if it.position == it.last_read_size {
		return nil, ReadDone{}
	}

	if it.position == len(it.buffer) {
		bytes_read := io.read_full(it.reader, it.buffer) or_return
		it.position = 0
		it.last_read_size = bytes_read
	}

	newline_index := bytes.index_any(it.buffer[it.position:], []byte{'\r', '\n'})
	if newline_index == -1 {
		bytes_read := io.read_at(it.reader, it.buffer, it.file_position) or_return
		it.position = 0
		it.last_read_size = bytes_read
		newline_index = bytes.index_any(it.buffer[it.position:], []byte{'\r', '\n'})
		if newline_index == -1 {
			return nil, BufferTooSmall{size = len(it.buffer)}
		}
	}

	// we have a newline marker in our buffer so we can return a slice into the buffer
	line = it.buffer[it.position:it.position + newline_index]
	it.position += newline_index + 1
	it.file_position += i64(newline_index + 1)

	return line, nil
}

@(test, private = "package")
test_line_iterator :: proc(t: ^testing.T) {
	context.logger = log.create_console_logger()

	buffer: [32]byte
	it, init_error := line_iterator_init("odinfmt.json", buffer[:])
	testing.expect_value(t, init_error, nil)

	line, read_error := line_iterator_next(&it)
	testing.expect_value(t, read_error, nil)
	testing.expect_value(t, string(line), "{")

	line, read_error = line_iterator_next(&it)
	testing.expect_value(t, read_error, nil)
	testing.expect_value(t, string(line), `  "character_width": 100,`)

	line, read_error = line_iterator_next(&it)
	testing.expect_value(t, read_error, nil)
	testing.expect_value(t, string(line), `  "tabs": true,`)

	line, read_error = line_iterator_next(&it)
	testing.expect_value(t, read_error, nil)
	testing.expect_value(t, string(line), `  "tabs_width": 4,`)

	line, read_error = line_iterator_next(&it)
	testing.expect_value(t, read_error, nil)
	testing.expect_value(t, string(line), `  "spaces": 2`)

	line, read_error = line_iterator_next(&it)
	testing.expect_value(t, read_error, nil)
	testing.expect_value(t, string(line), "}")

	line, read_error = line_iterator_next(&it)
	testing.expect_value(t, read_error, ReadDone{})
	testing.expect_value(t, string(line), "")

	too_small_buffer: [16]byte
	it, init_error = line_iterator_init("odinfmt.json", too_small_buffer[:])
	testing.expect_value(t, init_error, nil)

	line, read_error = line_iterator_next(&it)
	testing.expect_value(t, read_error, nil)
	testing.expect_value(t, string(line), "{")

	line, read_error = line_iterator_next(&it)
	testing.expect_value(t, read_error, BufferTooSmall{size = 16})
	testing.expect_value(t, string(line), "")
}
