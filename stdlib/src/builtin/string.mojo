# ===----------------------------------------------------------------------=== #
# Copyright (c) 2024, Modular Inc. All rights reserved.
#
# Licensed under the Apache License v2.0 with LLVM Exceptions:
# https://llvm.org/LICENSE.txt
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
# ===----------------------------------------------------------------------=== #
"""Implements basic object methods for working with strings.

These are Mojo built-ins, so you don't need to import them.
"""

from collections import List, KeyElement
from sys import llvm_intrinsic, bitwidthof

from memory import DTypePointer, LegacyPointer, UnsafePointer, memcmp, memcpy

from utils import StringRef, StaticIntTuple, StaticTuple
from utils._format import Formattable, Formatter, ToFormatter

from .io import _snprintf

# ===----------------------------------------------------------------------===#
# Utilties
# ===----------------------------------------------------------------------===#


@always_inline
fn _ctlz(val: Int) -> Int:
    return llvm_intrinsic["llvm.ctlz", Int, has_side_effect=False](val, False)


@always_inline("nodebug")
fn _ctlz(val: SIMD) -> __type_of(val):
    return llvm_intrinsic["llvm.ctlz", __type_of(val), has_side_effect=False](
        val, False
    )


# ===----------------------------------------------------------------------===#
# ord
# ===----------------------------------------------------------------------===#


fn ord(s: String) -> Int:
    """Returns an integer that represents the given one-character string.

    Given a string representing one character, return an integer
    representing the code point of that character. For example, `ord("a")`
    returns the integer `97`. This is the inverse of the `chr()` function.

    Args:
        s: The input string, which must contain only a single character.

    Returns:
        An integer representing the code point of the given character.
    """
    # UTF-8 to Unicode conversion:              (represented as UInt32 BE)
    # 1: 0aaaaaaa                            -> 00000000 00000000 00000000 0aaaaaaa     a
    # 2: 110aaaaa 10bbbbbb                   -> 00000000 00000000 00000aaa aabbbbbb     a << 6  | b
    # 3: 1110aaaa 10bbbbbb 10cccccc          -> 00000000 00000000 aaaabbbb bbcccccc     a << 12 | b << 6  | c
    # 4: 11110aaa 10bbbbbb 10cccccc 10dddddd -> 00000000 000aaabb bbbbcccc ccdddddd     a << 18 | b << 12 | c << 6 | d
    var p = s._as_ptr().bitcast[DType.uint8]()
    var b1 = p.load()
    if (b1 >> 7) == 0:  # This is 1 byte ASCII char
        debug_assert(len(s) == 1, "input string length must be 1")
        return int(b1)
    var num_bytes = _ctlz(~b1)
    debug_assert(len(s) == int(num_bytes), "input string must be one character")
    var shift = int((6 * (num_bytes - 1)))
    var b1_mask = 0b11111111 >> (num_bytes + 1)
    var result = int(b1 & b1_mask) << shift
    for i in range(1, num_bytes):
        p += 1
        shift -= 6
        result |= int(p.load() & 0b00111111) << shift
    return result


# ===----------------------------------------------------------------------===#
# chr
# ===----------------------------------------------------------------------===#


fn chr(c: Int) -> String:
    """Returns a string based on the given Unicode code point.

    Returns the string representing a character whose code point is the integer `c`.
    For example, `chr(97)` returns the string `"a"`. This is the inverse of the `ord()`
    function.

    Args:
        c: An integer that represents a code point.

    Returns:
        A string containing a single character based on the given code point.
    """
    # Unicode (represented as UInt32 BE) to UTF-8 conversion :
    # 1: 00000000 00000000 00000000 0aaaaaaa -> 0aaaaaaa                                a
    # 2: 00000000 00000000 00000aaa aabbbbbb -> 110aaaaa 10bbbbbb                       a >> 6  | 0b11000000, b       | 0b10000000
    # 3: 00000000 00000000 aaaabbbb bbcccccc -> 1110aaaa 10bbbbbb 10cccccc              a >> 12 | 0b11100000, b >> 6  | 0b10000000, c      | 0b10000000
    # 4: 00000000 000aaabb bbbbcccc ccdddddd -> 11110aaa 10bbbbbb 10cccccc 10dddddd     a >> 18 | 0b11110000, b >> 12 | 0b10000000, c >> 6 | 0b10000000, d | 0b10000000

    if (c >> 7) == 0:  # This is 1 byte ASCII char
        var p = DTypePointer[DType.int8].alloc(2)
        p.store(c)
        p.store(1, 0)
        return String(p, 2)

    @always_inline
    fn _utf8_len(val: Int) -> Int:
        debug_assert(val > 0x10FFFF, "Value is not a valid Unicode code point")
        alias sizes = SIMD[DType.int32, 4](
            0, 0b1111_111, 0b1111_1111_111, 0b1111_1111_1111_1111
        )
        var values = SIMD[DType.int32, 4](val)
        var mask = values > sizes
        return int(mask.cast[DType.uint8]().reduce_add())

    var num_bytes = _utf8_len(c)
    var p = DTypePointer[DType.uint8].alloc(num_bytes + 1)
    var shift = 6 * (num_bytes - 1)
    var mask = UInt8(0xFF) >> (num_bytes + 1)
    var num_bytes_marker = UInt8(0xFF) << (8 - num_bytes)
    p.store(((c >> shift) & mask) | num_bytes_marker)
    for i in range(1, num_bytes):
        shift -= 6
        p.store(i, ((c >> shift) & 0b00111111) | 0b10000000)
    p.store(num_bytes, 0)
    return String(p.bitcast[DType.int8](), num_bytes + 1)


# ===----------------------------------------------------------------------===#
# strtol
# ===----------------------------------------------------------------------===#


@always_inline
fn _atol(str_ref: StringRef, base: Int = 10) raises -> Int:
    """Parses the given string as an integer in the given base and returns that value.

    For example, `atol("19")` returns `19`. If the given string cannot be parsed
    as an integer value, an error is raised. For example, `atol("hi")` raises an
    error.

    If base is 0 the the string is parsed as an Integer literal,
    see: https://docs.python.org/3/reference/lexical_analysis.html#integers

    Args:
        str_ref: A string to be parsed as an integer in the given base.
        base: Base used for conversion, value must be between 2 and 36, or 0.

    Returns:
        An integer value that represents the string, or otherwise raises.
    """
    if (base != 0) and (base < 2 or base > 36):
        raise Error("Base must be >= 2 and <= 36, or 0.")
    if not str_ref:
        raise Error(_atol_error(base, str_ref))

    var real_base: Int
    var ord_num_max: Int

    var ord_letter_max = (-1, -1)
    var result = 0
    var is_negative: Bool = False
    var start: Int = 0
    var str_len = len(str_ref)
    var buff = str_ref._as_ptr()

    for pos in range(start, str_len):
        if isspace(buff[pos]):
            continue

        if str_ref[pos] == "-":
            is_negative = True
            start = pos + 1
        elif str_ref[pos] == "+":
            start = pos + 1
        else:
            start = pos
        break

    alias ord_0 = ord("0")
    # FIXME:
    #   Change this to `alias` after fixing support for __refitem__ of alias.
    var ord_letter_min = (ord("a"), ord("A"))
    alias ord_underscore = ord("_")

    if base == 0:
        var real_base_new_start = _identify_base(str_ref, start)
        real_base = real_base_new_start[0]
        start = real_base_new_start[1]
        if real_base == -1:
            raise Error(_atol_error(base, str_ref))
    else:
        real_base = base

    if real_base <= 10:
        ord_num_max = ord(str(real_base - 1))
    else:
        ord_num_max = ord("9")
        ord_letter_max = (
            ord("a") + (real_base - 11),
            ord("A") + (real_base - 11),
        )

    var found_valid_chars_after_start = False
    var has_space_after_number = False
    # single underscores are only allowed between DIGITS
    # starting "was_last_digit_undescore" to true such that
    # if the first digit is an undesrcore an error is raised
    var was_last_digit_undescore = True
    for pos in range(start, str_len):
        var ord_current = int(buff[pos])
        if ord_current == ord_underscore:
            if was_last_digit_undescore:
                raise Error(_atol_error(base, str_ref))
            else:
                was_last_digit_undescore = True
                continue
        else:
            was_last_digit_undescore = False
        if ord_0 <= ord_current <= ord_num_max:
            result += ord_current - ord_0
            found_valid_chars_after_start = True
        elif ord_letter_min[0] <= ord_current <= ord_letter_max[0]:
            result += ord_current - ord_letter_min[0] + 10
            found_valid_chars_after_start = True
        elif ord_letter_min[1] <= ord_current <= ord_letter_max[1]:
            result += ord_current - ord_letter_min[1] + 10
            found_valid_chars_after_start = True
        elif isspace(ord_current):
            has_space_after_number = True
            start = pos + 1
            break
        else:
            raise Error(_atol_error(base, str_ref))
        if pos + 1 < str_len and not isspace(buff[pos + 1]):
            var nextresult = result * real_base
            if nextresult < result:
                raise Error(
                    _atol_error(base, str_ref)
                    + " String expresses an integer too large to store in Int."
                )
            result = nextresult

    if was_last_digit_undescore or (not found_valid_chars_after_start):
        raise Error(_atol_error(base, str_ref))

    if has_space_after_number:
        for pos in range(start, str_len):
            if not isspace(buff[pos]):
                raise Error(_atol_error(base, str_ref))
    if is_negative:
        result = -result
    return result


fn _atol_error(base: Int, str_ref: StringRef) -> String:
    return (
        "String is not convertible to integer with base "
        + str(base)
        + ": '"
        + str(str_ref)
        + "'"
    )


fn _identify_base(str_ref: StringRef, start: Int) -> Tuple[Int, Int]:
    var length = len(str_ref)
    # just 1 digit, assume base 10
    if start == (length - 1):
        return 10, start
    if str_ref[start] == "0":
        var second_digit = str_ref[start + 1]
        if second_digit == "b" or second_digit == "B":
            return 2, start + 2
        if second_digit == "o" or second_digit == "O":
            return 8, start + 2
        if second_digit == "x" or second_digit == "X":
            return 16, start + 2
        # checking for special case of all "0", "_" are also allowed
        var was_last_character_underscore = False
        for i in range(start + 1, length):
            if str_ref[i] == "_":
                if was_last_character_underscore:
                    return -1, -1
                else:
                    was_last_character_underscore = True
                    continue
            else:
                was_last_character_underscore = False
            if str_ref[i] != "0":
                return -1, -1
    elif ord("1") <= ord(str_ref[start]) <= ord("9"):
        return 10, start
    else:
        return -1, -1

    return 10, start


fn atol(str: String, base: Int = 10) raises -> Int:
    """Parses the given string as an integer in the given base and returns that value.

    For example, `atol("19")` returns `19`. If the given string cannot be parsed
    as an integer value, an error is raised. For example, `atol("hi")` raises an
    error.

    If base is 0 the the string is parsed as an Integer literal,
    see: https://docs.python.org/3/reference/lexical_analysis.html#integers

    Args:
        str: A string to be parsed as an integer in the given base.
        base: Base used for conversion, value must be between 2 and 36, or 0.

    Returns:
        An integer value that represents the string, or otherwise raises.
    """
    return _atol(str._strref_dangerous(), base)


# ===----------------------------------------------------------------------===#
# isdigit
# ===----------------------------------------------------------------------===#


fn isdigit(c: Int8) -> Bool:
    """Determines whether the given character is a digit [0-9].

    Args:
        c: The character to check.

    Returns:
        True if the character is a digit.
    """
    alias ord_0 = ord("0")
    alias ord_9 = ord("9")
    return ord_0 <= int(c) <= ord_9


# ===----------------------------------------------------------------------===#
# isupper
# ===----------------------------------------------------------------------===#


fn isupper(c: Int8) -> Bool:
    """Determines whether the given character is an uppercase character.
       This currently only respects the default "C" locale, i.e. returns
       True only if the character specified is one of ABCDEFGHIJKLMNOPQRSTUVWXYZ.

    Args:
        c: The character to check.

    Returns:
        True if the character is uppercase.
    """
    return _is_ASCII_UPPERCASE(c)


fn _is_ASCII_UPPERCASE(c: Int8) -> Bool:
    alias ord_a = ord("A")
    alias ord_z = ord("Z")
    return ord_a <= int(c) <= ord_z


# ===----------------------------------------------------------------------===#
# islower
# ===----------------------------------------------------------------------===#


fn islower(c: Int8) -> Bool:
    """Determines whether the given character is an lowercase character.
       This currently only respects the default "C" locale, i.e. returns
       True only if the character specified is one of abcdefghijklmnopqrstuvwxyz.

    Args:
        c: The character to check.

    Returns:
        True if the character is lowercase.
    """
    return _is_ASCII_LOWERCASE(c)


fn _is_ASCII_LOWERCASE(c: Int8) -> Bool:
    alias ord_a = ord("a")
    alias ord_z = ord("z")
    return ord_a <= int(c) <= ord_z


# ===----------------------------------------------------------------------===#
# isspace
# ===----------------------------------------------------------------------===#


fn isspace(c: Int8) -> Bool:
    """Determines whether the given character is a whitespace character.
       This currently only respects the default "C" locale, i.e. returns
       True only if the character specified is one of
       " \n\t\r\f\v".

    Args:
        c: The character to check.

    Returns:
        True if the character is one of the whitespace characters listed above, otherwise False.
    """

    alias ord_space = ord(" ")
    alias ord_tab = ord("\t")
    alias ord_carriage_return = ord("\r")

    return c == ord_space or ord_tab <= int(c) <= ord_carriage_return


# ===----------------------------------------------------------------------===#
# String
# ===----------------------------------------------------------------------===#
struct String(
    Sized,
    Stringable,
    IntableRaising,
    KeyElement,
    Boolable,
    Formattable,
    ToFormatter,
):
    """Represents a mutable string."""

    alias _buffer_type = List[Int8]
    var _buffer: Self._buffer_type
    """The underlying storage for the string."""

    """ Usefull string aliases. """
    alias WHITESPACE = String(" \n\t\r\f\v")
    alias ASCII_LOWERCASE = String("abcdefghijklmnopqrstuvwxyz")
    alias ASCII_UPPERCASE = String("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
    alias ASCII_LETTERS = String.ASCII_LOWERCASE + String.ASCII_UPPERCASE
    alias DIGITS = String("0123456789")
    alias HEXDIGITS = String.DIGITS + String("abcdef") + String("ABCDEF")
    alias OCTDIGITS = String("01234567")
    alias PUNCTUATION = String("""!"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~""")
    alias PRINTABLE = String.DIGITS + String.ASCII_LETTERS + String.PUNCTUATION + String.WHITESPACE

    @always_inline
    fn __str__(self) -> String:
        return self

    @always_inline
    fn __repr__(self) -> String:
        """Return a Mojo-compatible representation of the `String` instance.

        You don't need to call this method directly, use `repr(my_string)` instead.
        """
        if "'" in self:
            return '"' + self + "'"
        else:
            return "'" + self + "'"

    # ===------------------------------------------------------------------===#
    # Initializers
    # ===------------------------------------------------------------------===#

    # TODO: Remove this method when #2317 is done
    @always_inline
    fn __init__(inout self, owned impl: Self._buffer_type):
        """Construct a string from a buffer of bytes.

        The buffer must be terminated with a null byte:

        ```mojo
        var buf = List[Int8]()
        buf.append(ord('H'))
        buf.append(ord('i'))
        buf.append(0)
        var hi = String(buf)
        ```

        Note that you should use the constructor from `List[UInt8]` instead
        as we are now storing the bytes as UInt8.

        See https://github.com/modularml/mojo/issues/2317 for more information.

        Args:
            impl: The buffer.
        """
        debug_assert(
            impl[-1] == 0,
            "expected last element of String buffer to be null terminator",
        )
        self._buffer = impl^

    @always_inline
    fn __init__(inout self, owned impl: List[UInt8]):
        """Construct a string from a buffer of bytes.

        The buffer must be terminated with a null byte:

        ```mojo
        var buf = List[UInt8]()
        buf.append(ord('H'))
        buf.append(ord('i'))
        buf.append(0)
        var hi = String(buf)
        ```

        Args:
            impl: The buffer.
        """
        debug_assert(
            impl[-1] == 0,
            "expected last element of String buffer to be null terminator",
        )
        # we store the length and capacity beforehand as `steal_data()` will invalidated `impl`
        var length = len(impl)
        var capacity = impl.capacity
        self._buffer = List[Int8](
            impl.steal_data().bitcast[Int8](), size=length, capacity=capacity
        )

    @always_inline
    fn __init__(inout self):
        """Construct an uninitialized string."""
        self._buffer = Self._buffer_type()

    @always_inline
    fn __init__(inout self, str: StringRef):
        """Construct a string from a StringRef object.

        Args:
            str: The StringRef from which to construct this string object.
        """
        var length = len(str)
        var buffer = Self._buffer_type()
        buffer.resize(length + 1, 0)
        memcpy(rebind[DTypePointer[DType.int8]](buffer.data), str.data, length)
        buffer[length] = 0
        self._buffer = buffer^

    @always_inline
    fn __init__(inout self, str: StringLiteral):
        """Constructs a String value given a constant string.

        Args:
            str: The input constant string.
        """

        self = String(StringRef(str))

    fn __init__[stringable: Stringable](inout self, value: stringable):
        """Creates a string from a value that conforms to Stringable trait.

        Parameters:
            stringable: The Stringable type.

        Args:
            value: The value that conforms to Stringable.
        """

        self = str(value)

    # TODO: Remove this method when #2317 is done
    @always_inline
    fn __init__(inout self, ptr: UnsafePointer[Int8], len: Int):
        """Creates a string from the buffer. Note that the string now owns
        the buffer.

        The buffer must be terminated with a null byte.

        Note that you should use the constructor from `UnsafePointer[UInt8]` instead
        as we are now storing the bytes as UInt8.

        See https://github.com/modularml/mojo/issues/2317 for more information.

        Args:
            ptr: The pointer to the buffer.
            len: The length of the buffer, including the null terminator.
        """
        # we don't know the capacity of ptr, but we'll assume it's the same or
        # larger than len
        self = Self(Self._buffer_type(ptr, size=len, capacity=len))

    @always_inline
    fn __init__(inout self, ptr: UnsafePointer[UInt8], len: Int):
        """Creates a string from the buffer. Note that the string now owns
        the buffer.

        The buffer must be terminated with a null byte.

        Args:
            ptr: The pointer to the buffer.
            len: The length of the buffer, including the null terminator.
        """
        # we don't know the capacity of ptr, but we'll assume it's the same or
        # larger than len
        self = Self(
            Self._buffer_type(ptr.bitcast[Int8](), size=len, capacity=len)
        )

    @always_inline
    fn __init__(inout self, ptr: LegacyPointer[Int8], len: Int):
        """Creates a string from the buffer. Note that the string now owns
        the buffer.

        The buffer must be terminated with a null byte.

        Args:
            ptr: The pointer to the buffer.
            len: The length of the buffer, including the null terminator.
        """
        self._buffer = Self._buffer_type()
        self._buffer.data = rebind[UnsafePointer[Int8]](ptr)
        self._buffer.size = len

    @always_inline
    fn __init__(inout self, ptr: DTypePointer[DType.int8], len: Int):
        """Creates a string from the buffer. Note that the string now owns
        the buffer.

        The buffer must be terminated with a null byte.

        Args:
            ptr: The pointer to the buffer.
            len: The length of the buffer, including the null terminator.
        """
        self = String(ptr.address, len)

    @always_inline
    fn __copyinit__(inout self, existing: Self):
        """Creates a deep copy of an existing string.

        Args:
            existing: The string to copy.
        """
        self._buffer = existing._buffer

    @always_inline
    fn __moveinit__(inout self, owned existing: String):
        """Move the value of a string.

        Args:
            existing: The string to move.
        """
        self._buffer = existing._buffer^

    @staticmethod
    @always_inline
    fn _from_bytes(owned buff: DTypePointer[DType.int8]) -> String:
        """Construct a string from a sequence of bytes.

        This does no validation that the given bytes are valid in any specific
        String encoding.

        Args:
            buff: The buffer. This should have an existing terminator.
        """

        return String(buff, len(StringRef(buff)) + 1)

    @staticmethod
    fn _from_bytes(owned buff: Self._buffer_type) -> String:
        """Construct a string from a sequence of bytes.

        This does no validation that the given bytes are valid in any specific
        String encoding.

        Args:
            buff: The buffer.
        """

        # If a terminator does not already exist, then add it.
        if buff[-1]:
            buff.append(0)

        return String(buff^)

    # ===------------------------------------------------------------------===#
    # Operator dunders
    # ===------------------------------------------------------------------===#

    @always_inline
    fn __bool__(self) -> Bool:
        """Checks if the string is not empty.

        Returns:
            True if the string length is greater than zero, and False otherwise.
        """
        return len(self) > 0

    fn __getitem__(self, idx: Int) -> String:
        """Gets the character at the specified position.

        Args:
            idx: The index value.

        Returns:
            A new string containing the character at the specified position.
        """
        if idx < 0:
            return self.__getitem__(len(self) + idx)

        debug_assert(0 <= idx < len(self), "index must be in range")
        var buf = Self._buffer_type(capacity=1)
        buf.append(self._buffer[idx])
        buf.append(0)
        return String(buf^)

    @always_inline
    fn _adjust_span(self, span: Slice) -> Slice:
        """Adjusts the span based on the string length."""
        var adjusted_span = span

        if adjusted_span.start < 0:
            adjusted_span.start = len(self) + adjusted_span.start

        if not adjusted_span._has_end():
            adjusted_span.end = len(self)
        elif adjusted_span.end < 0:
            adjusted_span.end = len(self) + adjusted_span.end

        if span.step < 0:
            var tmp = adjusted_span.end
            adjusted_span.end = adjusted_span.start - 1
            adjusted_span.start = tmp - 1

        return adjusted_span

    @always_inline
    fn __getitem__(self, span: Slice) -> String:
        """Gets the sequence of characters at the specified positions.

        Args:
            span: A slice that specifies positions of the new substring.

        Returns:
            A new string containing the string at the specified positions.
        """

        var adjusted_span = self._adjust_span(span)
        if adjusted_span.step == 1:
            return StringRef(
                self._buffer.data + span.start,
                len(adjusted_span),
            )

        var buffer = Self._buffer_type()
        var adjusted_span_len = len(adjusted_span)
        buffer.resize(adjusted_span_len + 1, 0)
        var ptr = self._as_ptr()
        for i in range(adjusted_span_len):
            buffer[i] = ptr[adjusted_span[i]]
        buffer[adjusted_span_len] = 0
        return Self(buffer^)

    @always_inline
    fn __len__(self) -> Int:
        """Returns the string length.

        Returns:
            The string length.
        """
        # Avoid returning -1 if the buffer is not initialized
        if not self._as_ptr():
            return 0

        # The negative 1 is to account for the terminator.
        return len(self._buffer) - 1

    @always_inline
    fn __eq__(self, other: String) -> Bool:
        """Compares two Strings if they have the same values.

        Args:
            other: The rhs of the operation.

        Returns:
            True if the Strings are equal and False otherwise.
        """
        if len(self) != len(other):
            return False

        if int(self._as_ptr()) == int(other._as_ptr()):
            return True

        return memcmp(self._as_ptr(), other._as_ptr(), len(self)) == 0

    @always_inline
    fn __ne__(self, other: String) -> Bool:
        """Compares two Strings if they do not have the same values.

        Args:
            other: The rhs of the operation.

        Returns:
            True if the Strings are not equal and False otherwise.
        """
        return not (self == other)

    @always_inline
    fn __add__(self, other: String) -> String:
        """Creates a string by appending another string at the end.

        Args:
            other: The string to append.

        Returns:
            The new constructed string.
        """
        if not self:
            return other
        if not other:
            return self
        var self_len = len(self)
        var other_len = len(other)
        var total_len = self_len + other_len
        var buffer = Self._buffer_type()
        buffer.resize(total_len + 1, 0)
        memcpy(
            DTypePointer(buffer.data),
            self._as_ptr(),
            self_len,
        )
        memcpy(
            DTypePointer(buffer.data + self_len),
            other._as_ptr(),
            other_len + 1,  # Also copy the terminator
        )
        return Self(buffer^)

    @always_inline
    fn __radd__(self, other: String) -> String:
        """Creates a string by prepending another string to the start.

        Args:
            other: The string to prepend.

        Returns:
            The new constructed string.
        """
        return other + self

    @always_inline
    fn __iadd__(inout self, other: String):
        """Appends another string to this string.

        Args:
            other: The string to append.
        """
        if not self:
            self = other
            return
        if not other:
            return
        var self_len = len(self)
        var other_len = len(other)
        var total_len = self_len + other_len
        self._buffer.resize(total_len + 1, 0)
        # Copy the data alongside the terminator.
        memcpy(
            self._as_uint8_ptr() + self_len,
            other._as_uint8_ptr(),
            other_len + 1,
        )

    # ===------------------------------------------------------------------=== #
    # Methods
    # ===------------------------------------------------------------------=== #

    @staticmethod
    fn format_sequence[*Ts: Formattable](*args: *Ts) -> Self:
        """
        Construct a string by concatenating a sequence of formattable arguments.

        Args:
            args: A sequence of formattable arguments.

        Parameters:
            Ts: The types of the arguments to format. Each type must be satisfy
              `Formattable`.

        Returns:
            A string formed by formatting the argument sequence.
        """

        var output = String()
        var writer = output._unsafe_to_formatter()

        @parameter
        fn write_arg[T: Formattable](arg: T):
            arg.format_to(writer)

        args.each[write_arg]()

        return output^

    fn format_to(self, inout writer: Formatter):
        """
        Formats this string to the provided formatter.

        Args:
            writer: The formatter to write to.
        """

        # SAFETY:
        #   Safe because `self` is borrowed, so its lifetime
        #   extends beyond this function.
        writer.write_str(self._strref_dangerous())

    fn _unsafe_to_formatter(inout self) -> Formatter:
        """
        Constructs a formatter that will write to this mutable string.

        Safety:
            The returned `Formatter` holds a mutable pointer to this `String`
            value. This `String` MUST outlive the `Formatter` instance.
        """

        fn write_to_string(ptr0: UnsafePointer[NoneType], strref: StringRef):
            var ptr: UnsafePointer[String] = ptr0.bitcast[String]()

            # FIXME:
            #   String.__iadd__ currently only accepts a String, meaning this
            #   RHS will allocate unneccessarily.
            ptr[] += strref

        return Formatter(
            write_to_string,
            # Arg data
            UnsafePointer.address_of(self).bitcast[NoneType](),
        )

    fn join[rank: Int](self, elems: StaticIntTuple[rank]) -> String:
        """Joins the elements from the tuple using the current string as a
        delimiter.

        Parameters:
            rank: The size of the tuple.

        Args:
            elems: The input tuple.

        Returns:
            The joined string.
        """
        if len(elems) == 0:
            return ""
        var curr = String(elems[0])
        for i in range(1, len(elems)):
            curr += self + String(elems[i])
        return curr

    fn join[*Types: Stringable](self, *elems: *Types) -> String:
        """Joins string elements using the current string as a delimiter.

        Parameters:
            Types: The types of the elements.

        Args:
            elems: The input values.

        Returns:
            The joined string.
        """

        var result: String = ""
        var is_first = True

        @parameter
        fn add_elt[T: Stringable](a: T):
            if is_first:
                is_first = False
            else:
                result += self
            result += str(a)

        elems.each[add_elt]()
        return result

    fn _strref_dangerous(self) -> StringRef:
        """
        Returns an inner pointer to the string as a StringRef.
        This functionality is extremely dangerous because Mojo eagerly releases
        strings.  Using this requires the use of the _strref_keepalive() method
        to keep the underlying string alive long enough.
        """
        return StringRef {data: self._as_ptr(), length: len(self)}

    fn _strref_keepalive(self):
        """
        A noop that keeps `self` alive through the call.  This
        can be carefully used with `_strref_dangerous()` to wield inner pointers
        without the string getting deallocated early.
        """
        pass

    # TODO: Remove this method when #2317 is done
    fn _as_ptr(self) -> DTypePointer[DType.int8]:
        """Retrieves a pointer to the underlying memory.

        Note that you should use `_as_uint8_ptr()` if you need to access the
        pointer as we are now storing the bytes as UInt8.

        See https://github.com/modularml/mojo/issues/2317 for more information.

        Returns:
            The pointer to the underlying memory.
        """
        return rebind[DTypePointer[DType.int8]](self._buffer.data)

    fn _as_uint8_ptr(self) -> DTypePointer[DType.uint8]:
        """Retrieves a pointer to the underlying memory.

        Returns:
            The pointer to the underlying memory.
        """
        return rebind[DTypePointer[DType.uint8]](
            self._buffer.data.bitcast[UInt8]()
        )

    fn as_bytes(self) -> List[Int8]:
        """Retrieves the underlying byte sequence encoding the characters in
        this string.

        This does not include the trailing null terminator.

        Returns:
            A sequence containing the encoded characters stored in this string.
        """

        # TODO(lifetimes): Return a reference rather than a copy
        var copy = self._buffer
        var last = copy.pop()
        debug_assert(
            last == 0,
            "expected last element of String buffer to be null terminator",
        )

        return copy

    fn _steal_ptr(inout self) -> DTypePointer[DType.int8]:
        """Transfer ownership of pointer to the underlying memory.
        The caller is responsible for freeing up the memory.

        Returns:
            The pointer to the underlying memory.
        """
        var ptr = self._as_ptr()
        self._buffer.data = UnsafePointer[Int8]()
        self._buffer.size = 0
        self._buffer.capacity = 0
        return ptr

    fn count(self, substr: String) -> Int:
        """Return the number of non-overlapping occurrences of substring
        `substr` in the string.

        If sub is empty, returns the number of empty strings between characters
        which is the length of the string plus one.

        Args:
          substr: The substring to count.

        Returns:
          The number of occurrences of `substr`.
        """
        if not substr:
            return len(self) + 1

        var res = 0
        var offset = 0

        while True:
            var pos = self.find(substr, offset)
            if pos == -1:
                break
            res += 1

            offset = pos + len(substr)

        return res

    fn __contains__(self, substr: String) -> Bool:
        """Returns True if the substring is contained within the current string.

        Args:
          substr: The substring to check.

        Returns:
          True if the string contains the substring.
        """
        return substr._strref_dangerous() in self._strref_dangerous()

    fn find(self, substr: String, start: Int = 0) -> Int:
        """Finds the offset of the first occurrence of `substr` starting at
        `start`. If not found, returns -1.

        Args:
          substr: The substring to find.
          start: The offset from which to find.

        Returns:
          The offset of `substr` relative to the beginning of the string.
        """

        return self._strref_dangerous().find(
            substr._strref_dangerous(), start=start
        )

    fn rfind(self, substr: String, start: Int = 0) -> Int:
        """Finds the offset of the last occurrence of `substr` starting at
        `start`. If not found, returns -1.

        Args:
          substr: The substring to find.
          start: The offset from which to find.

        Returns:
          The offset of `substr` relative to the beginning of the string.
        """

        return self._strref_dangerous().rfind(
            substr._strref_dangerous(), start=start
        )

    fn split(self, delimiter: String) raises -> List[String]:
        """Split the string by a delimiter.

        Args:
          delimiter: The string to split on.

        Returns:
          A List of Strings containing the input split by the delimiter.

        Raises:
          Error if an empty delimiter is specified.
        """
        if not delimiter:
            raise Error("empty delimiter not allowed to be passed to split.")

        var output = List[String]()

        var current_offset = 0
        while True:
            var loc = self.find(delimiter, current_offset)
            # delimiter not found, so add the search slice from where we're currently at
            if loc == -1:
                output.append(self[current_offset:])
                break

            # We found a delimiter, so add the preceding string slice
            output.append(self[current_offset:loc])

            # Advance our search offset past the delimiter
            current_offset = loc + len(delimiter)

        return output

    fn replace(self, old: String, new: String) -> String:
        """Return a copy of the string with all occurrences of substring `old`
        if replaced by `new`.

        Args:
          old: The substring to replace.
          new: The substring to replace with.

        Returns:
          The string where all occurences of `old` are replaced with `new`.
        """
        if not old:
            return self._interleave(new)

        var occurrences = self.count(old)
        if occurrences == -1:
            return self

        var self_start = self._as_ptr()
        var self_ptr = self._as_ptr()
        var new_ptr = new._as_ptr()

        var self_len = len(self)
        var old_len = len(old)
        var new_len = len(new)

        var res = List[Int8]()
        res.reserve(self_len + (old_len - new_len) * occurrences + 1)

        for _ in range(occurrences):
            var curr_offset = int(self_ptr) - int(self_start)

            var idx = self.find(old, curr_offset)

            debug_assert(idx >= 0, "expected to find occurrence during find")

            # Copy preceding unchanged chars
            for _ in range(curr_offset, idx):
                res.append(self_ptr.load())
                self_ptr += 1

            # Insert a copy of the new replacement string
            for i in range(new_len):
                res.append(new_ptr.load(i))

            self_ptr += old_len

        while True:
            var val = self_ptr.load()
            if val == 0:
                break
            res.append(self_ptr.load())
            self_ptr += 1

        res.append(0)
        return String(res^)

    fn strip(self, chars: String = " \n\t\r\f\v") -> String:
        """Return a copy of the string with leading and trailing characters removed.

        Args:
            chars: A set of characters to be removed. Defaults to whitespace.

        Returns:
          A copy of the string with no leading or trailing characters.
        """

        return self.lstrip(chars).rstrip(chars)

    fn rstrip(self, chars: String = " \n\t\r\f\v") -> String:
        """Return a copy of the string with trailing characters removed.

        Args:
            chars: A set of characters to be removed. Defaults to whitespace.

        Returns:
          A copy of the string with no trailing characters.
        """

        var r_idx = len(self)
        while r_idx > 0 and self[r_idx - 1] in chars:
            r_idx -= 1

        return self[:r_idx]

    fn lstrip(self, chars: String = " \n\t\r\f\v") -> String:
        """Return a copy of the string with leading characters removed.

        Args:
            chars: A set of characters to be removed. Defaults to whitespace.

        Returns:
          A copy of the string with no leading characters.
        """

        var l_idx = 0
        while l_idx < len(self) and self[l_idx] in chars:
            l_idx += 1

        return self[l_idx:]

    fn __hash__(self) -> Int:
        """Hash the underlying buffer using builtin hash.

        Returns:
            A 64-bit hash value. This value is _not_ suitable for cryptographic
            uses. Its intended usage is for data structures. See the `hash`
            builtin documentation for more details.
        """
        return hash(self._strref_dangerous())

    fn _interleave(self, val: String) -> String:
        var res = List[Int8]()
        var val_ptr = val._as_ptr()
        var self_ptr = self._as_ptr()
        res.reserve(len(val) * len(self) + 1)
        for i in range(len(self)):
            for j in range(len(val)):
                res.append(val_ptr.load(j))
            res.append(self_ptr.load(i))
        res.append(0)
        return String(res^)

    fn lower(self) -> String:
        """Returns a copy of the string with all ASCII cased characters
        converted to lowercase.

        Returns:
            A new string where cased letters have been convered to lowercase.
        """

        # TODO(#26444):
        # Support the Unicode standard casing behavior to handle cased letters
        # outside of the standard ASCII letters.
        return self._toggle_ascii_case[_is_ASCII_UPPERCASE]()

    fn upper(self) -> String:
        """Returns a copy of the string with all ASCII cased characters
        converted to uppercase.

        Returns:
            A new string where cased letters have been converted to uppercase.
        """

        # TODO(#26444):
        # Support the Unicode standard casing behavior to handle cased letters
        # outside of the standard ASCII letters.
        return self._toggle_ascii_case[_is_ASCII_LOWERCASE]()

    @always_inline
    fn _toggle_ascii_case[check_case: fn (Int8) -> Bool](self) -> String:
        var copy: String = self

        var char_ptr = copy._as_ptr()

        for i in range(len(self)):
            var char: Int8 = char_ptr[i]
            if check_case(char):
                var lower = _toggle_ascii_case(char)
                char_ptr[i] = lower

        return copy

    fn startswith(self, prefix: String, start: Int = 0, end: Int = -1) -> Bool:
        """Checks if the string starts with the specified prefix between start
        and end positions. Returns True if found and False otherwise.

        Args:
          prefix: The prefix to check.
          start: The start offset from which to check.
          end: The end offset from which to check.

        Returns:
          True if the self[start:end] is prefixed by the input prefix.
        """
        if end == -1:
            return self.find(prefix, start) == start
        return self[start:end].startswith(prefix)

    fn endswith(self, suffix: String, start: Int = 0, end: Int = -1) -> Bool:
        """Checks if the string end with the specified suffix between start
        and end positions. Returns True if found and False otherwise.

        Args:
          suffix: The suffix to check.
          start: The start offset from which to check.
          end: The end offset from which to check.

        Returns:
          True if the self[start:end] is suffixed by the input suffix.
        """
        if end == -1:
            return self._endswith_impl(suffix, start)
        return self[start:end]._endswith_impl(suffix)

    fn removeprefix(self, prefix: String, /) -> String:
        """If the string starts with the prefix string, return `string[len(prefix):]`.
        Otherwise, return a copy of the original string.

        ```mojo
        print(String('TestHook').removeprefix('Test'))
        # 'Hook'
        print(String('BaseTestCase').removeprefix('Test'))
        # 'BaseTestCase'
        ```

        Args:
          prefix: The prefix to remove from the string.

        Returns:
          A new string with the prefix removed if it was present.
        """
        if self.startswith(prefix):
            return self[len(prefix) :]
        return self

    fn removesuffix(self, suffix: String, /) -> String:
        """If the string ends with the suffix string, return `string[:-len(suffix)]`.
        Otherwise, return a copy of the original string.

        ```mojo
        print(String('TestHook').removesuffix('Hook'))
        # 'Test'
        print(String('BaseTestCase').removesuffix('Test'))
        # 'BaseTestCase'
        ```

        Args:
          suffix: The suffix to remove from the string.

        Returns:
          A new string with the suffix removed if it was present.
        """
        if self.endswith(suffix):
            return self[: -len(suffix)]
        return self

    @always_inline
    fn _endswith_impl(self, suffix: String, start: Int = 0) -> Bool:
        return self.rfind(suffix, start) + len(suffix) == len(self)

    fn __int__(self) raises -> Int:
        """Parses the given string as a base-10 integer and returns that value.

        For example, `int("19")` returns `19`. If the given string cannot be
        parsed as an integer value, an error is raised. For example, `int("hi")`
        raises an error.

        Returns:
            An integer value that represents the string, or otherwise raises.
        """
        return atol(self)

    fn __mul__(self, n: Int) -> String:
        """Concatenates the string `n` times.

        Args:
            n : The number of times to concatenate the string.

        Returns:
            The string concantenated `n` times.
        """
        if n <= 0:
            return ""
        var len_self = len(self)
        var count = len_self * n + 1
        var buf = Self._buffer_type(capacity=count)
        buf.resize(count, 0)
        for i in range(n):
            memcpy(
                rebind[DTypePointer[DType.int8]](buf.data) + len_self * i,
                self._as_ptr(),
                len_self,
            )
        return String(buf^)


# ===----------------------------------------------------------------------===#
# Utilities
# ===----------------------------------------------------------------------===#


@always_inline
fn _vec_fmt[
    *types: AnyType
](
    str: UnsafePointer[Int8],
    size: Int,
    fmt: StringLiteral,
    *arguments: *types,
) -> Int:
    return _snprintf(str, size, fmt, arguments)


fn _toggle_ascii_case(char: Int8) -> Int8:
    """Assuming char is a cased ASCII character, this function will return the opposite-cased letter
    """

    # ASCII defines A-Z and a-z as differing only in their 6th bit,
    # so converting is as easy as a bit flip.
    return char ^ (1 << 5)


fn _calc_initial_buffer_size_int32(n0: Int) -> Int:
    # See https://commaok.xyz/post/lookup_tables/ and
    # https://lemire.me/blog/2021/06/03/computing-the-number-of-DIGITS-of-an-integer-even-faster/
    # for a description.
    alias lookup_table = VariadicList[Int](
        4294967296,
        8589934582,
        8589934582,
        8589934582,
        12884901788,
        12884901788,
        12884901788,
        17179868184,
        17179868184,
        17179868184,
        21474826480,
        21474826480,
        21474826480,
        21474826480,
        25769703776,
        25769703776,
        25769703776,
        30063771072,
        30063771072,
        30063771072,
        34349738368,
        34349738368,
        34349738368,
        34349738368,
        38554705664,
        38554705664,
        38554705664,
        41949672960,
        41949672960,
        41949672960,
        42949672960,
        42949672960,
    )
    var n = UInt32(n0)
    var log2 = int((bitwidthof[DType.uint32]() - 1) ^ _ctlz(n | 1))
    return (n0 + lookup_table[int(log2)]) >> 32


fn _calc_initial_buffer_size_int64(n0: UInt64) -> Int:
    var result: Int = 1
    var n = n0
    while True:
        if n < 10:
            return result
        if n < 100:
            return result + 1
        if n < 1_000:
            return result + 2
        if n < 10_000:
            return result + 3
        n //= 10_000
        result += 4


@always_inline
fn _calc_initial_buffer_size(n0: Int) -> Int:
    var n = abs(n0)
    var sign = 0 if n0 > 0 else 1
    alias is_32bit_system = bitwidthof[DType.index]() == 32

    # Add 1 for the terminator
    @parameter
    if is_32bit_system:
        return sign + _calc_initial_buffer_size_int32(n) + 1

    # The value only has low-bits.
    if n >> 32 == 0:
        return sign + _calc_initial_buffer_size_int32(n) + 1
    return sign + _calc_initial_buffer_size_int64(n) + 1


fn _calc_initial_buffer_size(n: Float64) -> Int:
    return 128 + 1  # Add 1 for the terminator


fn _calc_initial_buffer_size[type: DType](n0: Scalar[type]) -> Int:
    @parameter
    if type.is_integral():
        var n = abs(n0)
        var sign = 0 if n0 > 0 else 1
        alias is_32bit_system = bitwidthof[DType.index]() == 32

        @parameter
        if is_32bit_system or bitwidthof[type]() <= 32:
            return sign + _calc_initial_buffer_size_int32(int(n)) + 1
        else:
            return (
                sign
                + _calc_initial_buffer_size_int64(n.cast[DType.uint64]())
                + 1
            )

    return 128 + 1  # Add 1 for the terminator
