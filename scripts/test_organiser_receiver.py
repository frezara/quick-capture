from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import sqlite3
import tempfile
import unittest
from organiser_receiver import Receiver, Rejected, canonical, digest, safe_read

FIXTURE = Path(__file__).resolve().parent.parent / 'integration/fixtures/request-v1.json'

class ReceiverTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.request = json.loads(FIXTURE.read_bytes())
        self.workspace = self.request['payload']['workspace_id']
        self.receiver = Receiver(self.root/'spool', self.root/'storage', self.workspace)
        self.bundle = self.root/'spool/requests'/self.request['payload']['capture']['capture_id']
        self.bundle.mkdir()
        self.publish()

    def tearDown(self):
        self.receiver.db.close()
        self.temp.cleanup()

    def publish(self):
        self.request['payload_sha256'] = digest(canonical(self.request['payload']))
        (self.bundle/'request.json').write_bytes(canonical(self.request))
        (self.bundle/'content.md').write_text(self.request['payload']['capture']['body_markdown'])

    def test_lost_receipt_restart_and_delete_preserve_acceptance(self):
        def crash(_):
            raise RuntimeError('simulated interruption')
        with self.assertRaises(RuntimeError):
            self.receiver.accept(self.bundle, fault=crash)
        self.assertEqual(self.receiver.db.execute('SELECT COUNT(*) FROM accepted').fetchone()[0], 1)
        self.assertEqual(list((self.root/'spool/receipts').iterdir()), [])
        self.receiver.db.close()
        self.receiver = Receiver(self.root/'spool', self.root/'storage', self.workspace)
        receipt = self.receiver.accept(self.bundle)
        self.receiver.db.execute('UPDATE accepted SET deleted=1')
        self.receiver.db.commit()
        self.assertEqual(self.receiver.accept(self.bundle), receipt)
        self.assertEqual(self.receiver.db.execute('SELECT COUNT(*),deleted FROM accepted').fetchone(), (1,1))

    def test_same_identity_changed_content_conflicts(self):
        self.receiver.accept(self.bundle)
        self.request['payload']['capture']['body_markdown'] = 'different'
        self.publish()
        with self.assertRaisesRegex(Rejected, 'conflict'):
            self.receiver.accept(self.bundle)
        self.assertEqual(self.receiver.db.execute('SELECT COUNT(*) FROM accepted').fetchone()[0], 1)

    def test_corrupt_digest_has_no_acceptance(self):
        self.request['payload_sha256'] = '0'*64
        (self.bundle/'request.json').write_bytes(canonical(self.request))
        with self.assertRaisesRegex(Rejected, 'digest_mismatch'):
            self.receiver.accept(self.bundle)
        self.assertEqual(self.receiver.db.execute('SELECT COUNT(*) FROM accepted').fetchone()[0], 0)

    def attachment(self):
        data = b'ordinary attachment bytes'
        (self.bundle/'attachments').mkdir()
        (self.bundle/'attachments/0').write_bytes(data)
        self.request['payload']['capture']['attachments'] = [{'attachment_id':'77777777-7777-4777-8777-777777777777','relative_path':'attachments/0','source_path':'attachments/photo.png','original_name':'photo.png','media_type':'image/png','byte_count':len(data),'sha256':digest(data)}]
        self.publish()
        return data

    def test_attachment_is_copied_and_body_preserved(self):
        expected = self.attachment()
        receipt = self.receiver.accept(self.bundle)
        (self.bundle/'attachments/0').unlink()
        item = self.root/'storage/items'/receipt['organiser_item_id']
        self.assertEqual((item/'attachments/0').read_bytes(), expected)
        self.assertEqual((item/'content.md').read_text(), self.request['payload']['capture']['body_markdown'])

    def test_corrupt_attachment_is_rejected(self):
        self.attachment()
        (self.bundle/'attachments/0').write_bytes(b'wrong')
        with self.assertRaisesRegex(Rejected, 'corrupt_attachment'):
            self.receiver.accept(self.bundle)
        self.assertEqual(self.receiver.db.execute('SELECT COUNT(*) FROM accepted').fetchone()[0], 0)

    def test_symlink_escape_is_rejected(self):
        self.attachment()
        attachment = self.bundle/'attachments/0'
        attachment.unlink()
        os.symlink(FIXTURE, attachment)
        with self.assertRaises(OSError):
            self.receiver.accept(self.bundle)

    def test_traversal_is_rejected(self):
        self.attachment()
        self.request['payload']['capture']['attachments'][0]['relative_path'] = '../outside'
        self.publish()
        with self.assertRaisesRegex(Rejected, 'unsafe_path'):
            self.receiver.accept(self.bundle)

    def test_unsupported_schema_and_wrong_workspace(self):
        self.request['payload']['capture']['schema_version'] = 2
        self.publish()
        with self.assertRaisesRegex(Rejected, 'unsupported_version'):
            self.receiver.accept(self.bundle)
        self.request['payload']['capture']['schema_version'] = 1
        self.request['payload']['workspace_id'] = '88888888-8888-4888-8888-888888888888'
        self.publish()
        with self.assertRaisesRegex(Rejected, 'wrong_workspace'):
            self.receiver.accept(self.bundle)

    def test_two_receivers_return_the_same_receipt(self):
        other = Receiver(self.root/'spool', self.root/'storage', self.workspace)
        try:
            first = self.receiver.accept(self.bundle)
            self.assertEqual(other.accept(self.bundle), first)
        finally:
            other.db.close()

    def test_simultaneous_workers_accept_one_item(self):
        def accept_in_thread(_):
            receiver = Receiver(self.root/'spool', self.root/'storage', self.workspace)
            try:
                return receiver.accept(self.bundle)
            finally:
                receiver.db.close()
        with ThreadPoolExecutor(max_workers=2) as pool:
            first, second = list(pool.map(accept_in_thread, range(2)))
        self.assertEqual(first, second)
        self.assertEqual(self.receiver.db.execute('SELECT COUNT(*) FROM accepted').fetchone()[0], 1)

    def test_interrupted_receipt_write_then_retry(self):
        # A directory where the receipt should be simulates a publication failure.
        target = self.root/'spool/receipts'/(self.bundle.name+'.json')
        target.mkdir()
        with self.assertRaises(OSError):
            self.receiver.accept(self.bundle)
        original = self.receiver.db.execute('SELECT receipt FROM accepted').fetchone()[0]
        target.rmdir()
        self.assertEqual(canonical(self.receiver.accept(self.bundle)), original)

    def test_no_partial_acceptance_if_required_attachment_absent(self):
        self.attachment()
        (self.bundle/'attachments/0').unlink()
        with self.assertRaises(OSError):
            self.receiver.accept(self.bundle)
        self.assertEqual(self.receiver.db.execute('SELECT COUNT(*) FROM accepted').fetchone()[0], 0)

if __name__ == '__main__':
    unittest.main()
