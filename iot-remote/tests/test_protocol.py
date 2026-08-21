import unittest

from iot_remote.protocol import build_downlink, parse_d0, parse_frame, split_frames


class ProtocolTests(unittest.TestCase):
    def test_parse_and_build(self):
        raw = build_downlink("ZZ", "000000000000001", "v0", ["2"])
        self.assertEqual(raw, b"\xff\xff*SCOS,ZZ,000000000000001,V0,2#\r\n")

        frame = parse_frame(b"*SCOR,ZZ,000000000000001,V0,2#\r\n")
        self.assertIsNotNone(frame)
        self.assertEqual(frame.header, "*SCOR")
        self.assertEqual(frame.function, "V0")
        self.assertEqual(frame.fields, ("2",))

    def test_split_fragmented_and_coalesced_frames(self):
        frames, tail = split_frames(
            b"noise*SCOR,ZZ,000000000000001,Q0,0,99,31#\r\n*SCOR,ZZ,000000000000001,H"
        )
        self.assertEqual(frames, [b"*SCOR,ZZ,000000000000001,Q0,0,99,31#"])
        self.assertEqual(tail, b"*SCOR,ZZ,000000000000001,H")
        frames, tail = split_frames(tail + b"0,1,412,31,99,0#\r\n")
        self.assertEqual(len(frames), 1)
        self.assertEqual(tail, b"")

    def test_synthetic_h0_d0_and_s6_samples(self):
        h0 = parse_frame(b"*SCOR,ZZ,000000000000001,H0,1,400,20,80,0#")
        d0 = parse_frame(b"*SCOR,ZZ,000000000000001,D0,0,120000.00,V,,,,,00,99.99,010100,,,N#")
        s6 = parse_frame(b"*SCOR,ZZ,000000000000001,S6,80,12000,0,24000,0,0,0,0#")
        self.assertEqual(h0.fields, ("1", "400", "20", "80", "0"))
        self.assertEqual(d0.fields[2], "V")
        self.assertEqual(s6.fields[0], "80")

    def test_parse_valid_d0_converts_nmea_to_wgs84(self):
        report = parse_d0((
            "0", "000000.00", "A", "0100.0000", "N", "00100.0000", "E",
            "6", "0.21", "010100", "10", "M", "A",
        ))
        self.assertIsNotNone(report)
        self.assertTrue(report.valid)
        self.assertEqual(report.source, "once")
        self.assertAlmostEqual(report.latitude, 1.0, places=5)
        self.assertAlmostEqual(report.longitude, 1.0, places=5)
        self.assertEqual(report.satellites, 6)
        self.assertEqual(report.hdop, 0.21)
        self.assertIsNotNone(report.device_timestamp)

    def test_parse_invalid_d0_preserves_diagnostics_without_coordinates(self):
        report = parse_d0((
            "0", "120000.00", "V", "", "", "", "", "00", "99.99",
            "010100", "", "", "N",
        ))
        self.assertIsNotNone(report)
        self.assertFalse(report.valid)
        self.assertIsNone(report.latitude)
        self.assertEqual(report.satellites, 0)
        self.assertEqual(report.mode, "N")

        self.assertIsNone(parse_d0((
            "0", "000000.00", "A", "0161.0000", "N", "00100.0000", "E",
            "6", "0.21", "010100", "10", "M", "A",
        )))

    def test_invalid_frame_is_rejected(self):
        self.assertIsNone(parse_frame(b"YW*1*Q0"))
        self.assertIsNone(parse_frame(b"[YW**Q0]"))
        with self.assertRaises(ValueError):
            build_downlink("ZZ", "000000000000001", "V0", ["bad,field"])


if __name__ == "__main__":
    unittest.main()
