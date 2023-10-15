package file_utilities

import "core:bytes"
import "core:io"
import "core:log"
import "core:mem"
import "core:os"
import "core:slice"
import "core:testing"

ReadLineError :: union {
	BufferTooSmall,
	io.Error,
	ReadDone,
	mem.Allocator_Error,
}

OpenFileError :: union {
	OpenError,
}

OpenError :: struct {
	filename: string,
	error:    os.Errno,
}

ReaderCreateError :: struct {
	filename: string,
	stream:   io.Stream,
}

ReadDone :: struct {}

LineIterator :: struct {
	stream:         io.Stream,
	buffer:         []byte,
	position:       int,
	file_position:  i64,
	last_read_size: int,
	allocator:      Maybe(mem.Allocator),
	slices:         [dynamic][]byte,
}

BufferTooSmall :: struct {
	size: int,
}

// Creates an `io.Stream` directly from a filename. This is analogous to
// `os.open` -> `os.stream_from_handle`.
open_file_stream :: proc(filename: string) -> (r: io.Stream, error: OpenFileError) {
	handle, open_error := os.open(filename, os.O_RDONLY)
	if open_error != os.ERROR_NONE {
		return io.Stream{}, OpenError{filename = filename, error = open_error}
	}

	return os.stream_from_handle(handle), nil
}

// Returns a `LineIterator` to be used with `line_iterator_next`. Note that each line returned will
// only be valid until the next call to `line_iterator_next` and that you should use
// `line_iterator_init_with_allocator` if you want to keep lines around, or copy them yourself.
line_iterator_init :: proc(stream: io.Stream, buffer: []byte) -> (it: LineIterator) {
	it.stream = stream
	it.position = len(buffer)
	it.buffer = buffer
	it.last_read_size = -1

	return it
}

// Returns a `LineIterator` to be used with `line_iterator_next`. Takes an allocator that will make
// it so that each line returned is copied, allowing for the caller to keep lines around for later.
line_iterator_init_with_allocator :: proc(
	reader: io.Reader,
	buffer: []byte,
	allocator: mem.Allocator,
) -> (
	it: LineIterator,
	error: mem.Allocator_Error,
) {
	it = line_iterator_init(reader, buffer)
	it.allocator = allocator
	it.slices = make([dynamic][]byte, 0, 0, allocator) or_return

	return it, nil
}

// Closes the underlying stream that the iterator uses. Note that this does not free/destroy any
// potentially allocated memory that the iterator is responsible for.
line_iterator_close :: proc(it: ^LineIterator) {
	io.close(it.stream)
}

// Destroys any resources that the iterator is responsible for. This is a no-op if the iterator was
// initialized without an allocator.
line_iterator_destroy :: proc(it: ^LineIterator) {
	if it.allocator != nil {
		for slice in it.slices {
			delete(slice, it.allocator.?)
		}
		delete(it.slices)
	}
}

// Returns the next line in the iterator or `ReadDone` if there are no more lines to read. Note
// that unless the iterator was created with an allocator the returned lines are only valid until
// the next call to `line_iterator_next`. The internal buffer changes over time.
line_iterator_next :: proc(it: ^LineIterator) -> (line: []byte, error: ReadLineError) {
	assert(it.position <= len(it.buffer), "Position in `LineIterator` out of bounds")

	if it.position == it.last_read_size {
		return nil, ReadDone{}
	}

	if it.position == len(it.buffer) {
		bytes_read := io.read_full(it.stream, it.buffer) or_return
		it.position = 0
		it.last_read_size = bytes_read
	}

	newline_index := bytes.index_any(it.buffer[it.position:], []byte{'\r', '\n'})
	if newline_index == -1 {
		bytes_read := io.read_at(it.stream, it.buffer, it.file_position) or_return
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
	if it.allocator != nil {
		line = slice.clone(line, it.allocator.?) or_return
		append(&it.slices, line) or_return
	}

	return line, nil
}

@(test, private = "package")
test_line_iterator :: proc(t: ^testing.T) {
	context.logger = log.create_console_logger()

	buffer: [32]byte
	reader, _ := open_file_stream("odinfmt.json")
	it := line_iterator_init(reader, buffer[:])

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

	// buffer is too small
	too_small_buffer: [16]byte
	reader, _ = open_file_stream("odinfmt.json")
	it = line_iterator_init(reader, too_small_buffer[:])

	line, read_error = line_iterator_next(&it)
	testing.expect_value(t, read_error, nil)
	testing.expect_value(t, string(line), "{")

	line, read_error = line_iterator_next(&it)
	testing.expect_value(t, read_error, BufferTooSmall{size = 16})
	testing.expect_value(t, string(line), "")

	// file does not exist
	_, open_error := open_file_stream("does_not_exist")
	testing.expect_value(t, open_error, OpenError{filename = "does_not_exist", error = os.ENOENT})

	// with allocator set
	tracking_allocator: mem.Tracking_Allocator
	mem.tracking_allocator_init(&tracking_allocator, context.allocator)
	defer mem.tracking_allocator_destroy(&tracking_allocator)
	allocator := mem.tracking_allocator(&tracking_allocator)
	reader, _ = open_file_stream("odinfmt.json")
	init_error: mem.Allocator_Error
	it, init_error = line_iterator_init_with_allocator(reader, buffer[:], allocator)
	testing.expect_value(t, init_error, nil)

	line1, read_error1 := line_iterator_next(&it)
	testing.expect_value(t, read_error1, nil)
	line2, read_error2 := line_iterator_next(&it)
	testing.expect_value(t, read_error2, nil)
	line3, read_error3 := line_iterator_next(&it)
	testing.expect_value(t, read_error3, nil)
	line4, read_error4 := line_iterator_next(&it)
	testing.expect_value(t, read_error4, nil)
	line5, read_error5 := line_iterator_next(&it)
	testing.expect_value(t, read_error5, nil)
	line6, read_error6 := line_iterator_next(&it)
	testing.expect_value(t, read_error6, nil)

	testing.expect_value(t, string(line1), "{")
	testing.expect_value(t, string(line2), `  "character_width": 100,`)
	testing.expect_value(t, string(line3), `  "tabs": true,`)
	testing.expect_value(t, string(line4), `  "tabs_width": 4,`)
	testing.expect_value(t, string(line5), `  "spaces": 2`)
	testing.expect_value(t, string(line6), "}")

	line_iterator_destroy(&it)

	testing.expect_value(t, len(tracking_allocator.allocation_map), 0)
	if len(tracking_allocator.allocation_map) > 0 {
		log.errorf("Leaks:")
		for k, v in tracking_allocator.allocation_map {
			log.errorf("\t%v: %v\n", k, v)
		}
	}
}
