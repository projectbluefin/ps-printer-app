"""Unit tests for tests/ipp-request.py, the IPP client the appliance suites trust.

core-appliance.sh, print-routes.sh and instance-isolation.sh read the status,
job-id, job-state and system attributes this client prints, so a wrong
encoding or a mis-parsed response would make those suites pass or fail for the
wrong reason. These tests pin the wire format of the request it sends, the
response parser and the refusals of its command line against a local HTTP
server, with no printer application involved.

Run with: python3 -m unittest discover -s tests -p 'test_ipp_request.py'
"""
import contextlib
import http.server
import importlib.util
import io
import os
import struct
import sys
import tempfile
import threading
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
SPEC = importlib.util.spec_from_file_location("ipp_request", os.path.join(HERE, "ipp-request.py"))
ipp = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ipp)


def response(status: int, *groups: bytes, request_id: int = 1, trailer: bytes = b"") -> bytes:
    """An IPP/2.0 response: header, the given raw groups and an end tag."""
    return struct.pack(">BBHI", 2, 0, status, request_id) + b"".join(groups) + b"\x03" + trailer


def read_attributes(body: bytes, offset: int):
    """Decode the request groups after the 8-byte header into (tag, name, value) triples.

    Delimiter tags are recorded as (tag, None, None). Returns the triples and
    the offset just past the end-of-attributes tag.
    """
    items = []
    while True:
        tag = body[offset]
        offset += 1
        if tag == 0x03:
            return items, offset
        if tag < 0x10:
            items.append((tag, None, None))
            continue
        name_length = struct.unpack(">H", body[offset:offset + 2])[0]
        offset += 2
        name = body[offset:offset + name_length].decode("ascii")
        offset += name_length
        value_length = struct.unpack(">H", body[offset:offset + 2])[0]
        offset += 2
        items.append((tag, name, body[offset:offset + value_length]))
        offset += value_length


class AttributeEncodingTests(unittest.TestCase):
    def test_text_value_is_length_prefixed_utf8(self):
        self.assertEqual(
            ipp.attribute(0x42, "job-name", "café"),
            b"\x42\x00\x08job-name\x00\x05caf\xc3\xa9",
        )

    def test_integer_value_is_four_byte_signed_big_endian(self):
        self.assertEqual(ipp.attribute(0x21, "job-id", 7), b"\x21\x00\x06job-id\x00\x04\x00\x00\x00\x07")
        self.assertEqual(ipp.attribute(0x21, "x", -1)[-4:], b"\xff\xff\xff\xff")


class DecodeTests(unittest.TestCase):
    def test_integer_and_enum_are_decimal(self):
        self.assertEqual(ipp.decode(0x21, struct.pack(">i", 42)), "42")
        self.assertEqual(ipp.decode(0x23, struct.pack(">i", 9)), "9")
        self.assertEqual(ipp.decode(0x21, struct.pack(">i", -3)), "-3")

    def test_integer_of_the_wrong_length_falls_back_to_hex(self):
        self.assertEqual(ipp.decode(0x21, b"\x00\x01"), "0001")

    def test_boolean(self):
        self.assertEqual(ipp.decode(0x22, b"\x01"), "true")
        self.assertEqual(ipp.decode(0x22, b"\x00"), "false")
        self.assertEqual(ipp.decode(0x22, b"\x00\x01"), "0001")

    def test_every_character_string_tag_is_text(self):
        for tag in range(0x40, 0x50):
            with self.subTest(tag=hex(tag)):
                self.assertEqual(ipp.decode(tag, "Généric".encode()), "Généric")

    def test_invalid_utf8_is_replaced_not_raised(self):
        self.assertEqual(ipp.decode(0x41, b"a\xffb"), "a\ufffdb")

    def test_other_tags_are_hex(self):
        self.assertEqual(ipp.decode(0x30, b"\xde\xad"), "dead")
        self.assertEqual(ipp.decode(0x13, b""), "")


class ParseTests(unittest.TestCase):
    def test_short_response_is_refused(self):
        for body in (b"", b"\x02\x00\x00\x00\x00\x00\x00"):
            with self.subTest(length=len(body)):
                with self.assertRaisesRegex(ValueError, "short IPP response"):
                    ipp.parse(body)

    def test_status_comes_from_bytes_two_and_three(self):
        status, attributes = ipp.parse(response(0x0400))
        self.assertEqual(status, 0x0400)
        self.assertEqual(attributes, {})

    def test_header_without_end_tag_parses(self):
        self.assertEqual(ipp.parse(struct.pack(">BBHI", 2, 0, 0x0001, 1)), (0x0001, {}))

    def test_attributes_across_groups(self):
        body = response(
            0x0000,
            b"\x01",
            ipp.attribute(0x47, "attributes-charset", "utf-8"),
            b"\x02",
            ipp.attribute(0x21, "job-id", 12),
            ipp.attribute(0x23, "job-state", 9),
            b"\x04",
            ipp.attribute(0x41, "printer-make-and-model", "Generic PostScript Printer"),
        )
        status, attributes = ipp.parse(body)
        self.assertEqual(status, 0)
        self.assertEqual(
            attributes,
            {
                "attributes-charset": ["utf-8"],
                "job-id": ["12"],
                "job-state": ["9"],
                "printer-make-and-model": ["Generic PostScript Printer"],
            },
        )

    def test_additional_values_join_the_previous_name(self):
        body = response(
            0x0000,
            b"\x04",
            ipp.attribute(0x44, "printer-state-reasons", "none"),
            ipp.attribute(0x44, "", "media-low"),
            ipp.attribute(0x44, "", "toner-low"),
            ipp.attribute(0x21, "queued-job-count", 0),
        )
        _, attributes = ipp.parse(body)
        self.assertEqual(attributes["printer-state-reasons"], ["none", "media-low", "toner-low"])
        self.assertEqual(attributes["queued-job-count"], ["0"])

    def test_repeated_name_accumulates(self):
        body = response(0x0000, b"\x04", ipp.attribute(0x44, "a", "x"), b"\x04", ipp.attribute(0x44, "a", "y"))
        self.assertEqual(ipp.parse(body)[1], {"a": ["x", "y"]})

    def test_bytes_after_the_end_tag_are_not_attributes(self):
        trailer = ipp.attribute(0x44, "injected", "after-end")
        body = response(0x0000, b"\x04", ipp.attribute(0x44, "kept", "yes"), trailer=trailer)
        self.assertEqual(ipp.parse(body)[1], {"kept": ["yes"]})

    def test_out_of_band_value_is_kept_with_empty_value(self):
        body = response(0x0000, b"\x04", ipp.attribute(0x13, "printer-alert", ""))
        self.assertEqual(ipp.parse(body)[1], {"printer-alert": [""]})


class _Recorder(http.server.BaseHTTPRequestHandler):
    """Records each POST and answers with the server's canned reply."""

    def do_POST(self):  # noqa: N802 - http.server API
        length = int(self.headers.get("Content-Length", "0"))
        self.server.requests.append(
            {"path": self.path, "content_type": self.headers.get("Content-Type"), "body": self.rfile.read(length)}
        )
        content_type, body = self.server.reply
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


class MainTests(unittest.TestCase):
    def setUp(self):
        self.server = http.server.HTTPServer(("127.0.0.1", 0), _Recorder)
        self.server.requests = []
        self.server.reply = ("application/ipp", response(0x0000))
        self.thread = threading.Thread(target=self.server.serve_forever, kwargs={"poll_interval": 0.05}, daemon=True)
        self.thread.start()
        self.addCleanup(self.thread.join)
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)
        self.authority = f"127.0.0.1:{self.server.server_address[1]}"
        self.printer = f"ipp://{self.authority}/ipp/print/ps"

    def run_main(self, *args):
        stdout, stderr = io.StringIO(), io.StringIO()
        with mock.patch.object(sys, "argv", ["ipp-request.py", *args]), \
                contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            code = ipp.main()
        return code, stdout.getvalue(), stderr.getvalue()

    def only_request(self):
        self.assertEqual(len(self.server.requests), 1)
        return self.server.requests[0]

    def document(self, data: bytes) -> str:
        handle = tempfile.NamedTemporaryFile(delete=False)
        self.addCleanup(os.unlink, handle.name)
        with handle:
            handle.write(data)
        return handle.name

    # Request encoding.

    def test_get_printer_attributes_request(self):
        code, _, _ = self.run_main(self.printer, "get-printer-attributes")
        self.assertEqual(code, 0)
        sent = self.only_request()
        self.assertEqual(sent["path"], "/ipp/print/ps")
        self.assertEqual(sent["content_type"], "application/ipp")
        body = sent["body"]
        self.assertEqual(struct.unpack(">BBHI", body[:8]), (2, 0, 0x000B, 1))
        items, end = read_attributes(body, 8)
        self.assertEqual(
            items,
            [
                (0x01, None, None),
                (0x47, "attributes-charset", b"utf-8"),
                (0x48, "attributes-natural-language", b"en"),
                (0x45, "printer-uri", self.printer.encode()),
                (0x42, "requesting-user-name", b"appliance-test"),
            ],
        )
        self.assertEqual(end, len(body), "nothing may follow the end tag without a document")

    def test_get_system_attributes_addresses_the_system_uri(self):
        system = f"ipp://{self.authority}/ipp/system"
        code, _, _ = self.run_main(system, "get-system-attributes")
        self.assertEqual(code, 0)
        body = self.only_request()["body"]
        self.assertEqual(struct.unpack(">H", body[2:4])[0], 0x005B)
        items, _ = read_attributes(body, 8)
        self.assertIn((0x45, "system-uri", system.encode()), items)
        self.assertNotIn("printer-uri", [name for _, name, _ in items])

    def test_get_job_attributes_sends_integer_job_id(self):
        code, _, _ = self.run_main(self.printer, "get-job-attributes", "17")
        self.assertEqual(code, 0)
        body = self.only_request()["body"]
        self.assertEqual(struct.unpack(">H", body[2:4])[0], 0x0009)
        items, _ = read_attributes(body, 8)
        self.assertEqual(items[-1], (0x21, "job-id", struct.pack(">i", 17)))

    def test_print_job_sends_job_attributes_group_and_document(self):
        document = b"%!PS-Adobe-3.0\nshowpage\n\x00\x03\xff"
        path = self.document(document)
        code, _, _ = self.run_main(
            self.printer, "print-job", path, "application/postscript", "secure-printing=on", "print-quality=high"
        )
        self.assertEqual(code, 0)
        body = self.only_request()["body"]
        self.assertEqual(struct.unpack(">H", body[2:4])[0], 0x0002)
        items, end = read_attributes(body, 8)
        self.assertEqual(
            items[5:],
            [
                (0x42, "job-name", b"appliance-test"),
                (0x49, "document-format", b"application/postscript"),
                (0x02, None, None),
                (0x44, "secure-printing", b"on"),
                (0x44, "print-quality", b"high"),
            ],
        )
        self.assertEqual(body[end:], document, "the document follows the end tag byte for byte")

    def test_print_job_without_settings_has_no_job_group(self):
        path = self.document(b"%!PS\n")
        code, _, _ = self.run_main(self.printer, "print-job", path, "application/postscript")
        self.assertEqual(code, 0)
        items, end = read_attributes(self.only_request()["body"], 8)
        self.assertNotIn((0x02, None, None), items)
        self.assertEqual(self.only_request()["body"][end:], b"%!PS\n")

    def test_setting_value_may_contain_equals(self):
        path = self.document(b"x")
        code, _, _ = self.run_main(self.printer, "print-job", path, "text/plain", "job-password=a=b")
        self.assertEqual(code, 0)
        items, _ = read_attributes(self.only_request()["body"], 8)
        self.assertEqual(items[-1], (0x44, "job-password", b"a=b"))

    # Response output.

    def test_prints_status_and_attributes_in_response_order(self):
        self.server.reply = (
            "application/ipp; charset=utf-8",
            response(
                0x0001,
                b"\x01",
                ipp.attribute(0x47, "attributes-charset", "utf-8"),
                b"\x02",
                ipp.attribute(0x21, "job-id", 3),
                ipp.attribute(0x44, "job-state-reasons", "job-incoming"),
                ipp.attribute(0x44, "", "job-printing"),
            ),
        )
        code, out, err = self.run_main(self.printer, "get-job-attributes", "3")
        self.assertEqual((code, err), (0, ""))
        self.assertEqual(
            out.splitlines(),
            ["status=0x0001", "attributes-charset=utf-8", "job-id=3", "job-state-reasons=job-incoming,job-printing"],
        )

    def test_error_status_is_printed_not_turned_into_success(self):
        self.server.reply = ("application/ipp", response(0x0406))
        code, out, _ = self.run_main(self.printer, "get-printer-attributes")
        self.assertEqual(code, 0, "the status line, not the exit code, carries the IPP status")
        self.assertEqual(out.splitlines(), ["status=0x0406"])

    def test_non_ipp_response_fails(self):
        self.server.reply = ("text/html", b"<html>web interface</html>")
        code, out, err = self.run_main(self.printer, "get-printer-attributes")
        self.assertEqual(code, 1)
        self.assertEqual(out, "")
        self.assertIn("not an IPP response: Content-Type 'text/html'", err)

    # Command line refusals: nothing may reach the server.

    def assert_refused(self, args, message):
        code, out, err = self.run_main(*args)
        self.assertEqual(code, 2)
        self.assertEqual(out, "")
        self.assertIn(message, err)
        self.assertEqual(self.server.requests, [])

    def test_missing_or_unknown_operation_prints_usage(self):
        for args in ((), (self.printer,), (self.printer, "cancel-job")):
            with self.subTest(args=args):
                self.assert_refused(args, "Usage:")

    def test_non_ipp_uri_is_refused(self):
        self.assert_refused((f"http://{self.authority}/ipp/print/ps", "get-printer-attributes"), "not an ipp:// URI")

    def test_print_job_needs_file_and_mime_type(self):
        self.assert_refused((self.printer, "print-job"), "print-job needs FILE and MIME_TYPE")
        self.assert_refused((self.printer, "print-job", "/nonexistent"), "print-job needs FILE and MIME_TYPE")

    def test_malformed_job_setting_is_refused(self):
        path = self.document(b"x")
        for setting in ("secure-printing", "=on", "secure-printing="):
            with self.subTest(setting=setting):
                self.assert_refused(
                    (self.printer, "print-job", path, "text/plain", setting), "job attribute is not NAME=KEYWORD"
                )

    def test_get_job_attributes_needs_exactly_one_job_id(self):
        self.assert_refused((self.printer, "get-job-attributes"), "get-job-attributes needs JOB_ID")
        self.assert_refused((self.printer, "get-job-attributes", "1", "2"), "get-job-attributes needs JOB_ID")

    def test_attribute_operations_take_no_extra_arguments(self):
        self.assert_refused((self.printer, "get-printer-attributes", "extra"), "takes no further arguments")
        self.assert_refused((self.printer, "get-system-attributes", "extra"), "takes no further arguments")


if __name__ == "__main__":
    unittest.main()
