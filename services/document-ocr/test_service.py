import io
import unittest
from unittest.mock import patch
from fastapi.testclient import TestClient
from PIL import Image
import app
from normalize import normalize_page

class ScannerTests(unittest.TestCase):
    def test_cells_and_geometry(self):
        text,tables,low=normalize_page({'res':{'overall_ocr_res':{'rec_texts':['Qty','Item','2'], 'rec_boxes':[[100,0,130,10],[0,0,50,10],[100,20,130,30]], 'rec_scores':[.95,.6,.95]}, 'table_res_list':[{'pred_html':'<table><tr><th>Item</th><th>Qty</th></tr><tr><td>Camera<br>Serial: A&amp;B</td><td>2</td></tr></table>'}]}})
        self.assertEqual(text,'Item Qty\n2')
        self.assertEqual(tables[0][1][0],'Camera\nSerial: A&B')
        self.assertEqual(low,1)

    def test_upload_requires_session(self):
        response=TestClient(app.app).post('/scan',data={'company_id':'00000000-0000-0000-0000-000000000001'},files={'file':('bill.png',b'fake','image/png')})
        self.assertEqual(response.status_code,401)

    @patch('app.authorize')
    def test_invalid_image_does_not_run_inference(self, auth):
        with patch('app.subprocess.run') as run:
            response=TestClient(app.app).post('/scan',data={'company_id':'x'},files={'file':('bill.png',b'not an image','image/png')})
            self.assertEqual(response.status_code,400)
            run.assert_not_called()

    @patch('app.authorize')
    def test_inference_result_and_temp_cleanup(self, auth):
        image=io.BytesIO();Image.new('RGB',(20,20),'white').save(image,format='PNG')
        def infer(args,**kwargs):
            from pathlib import Path
            self.input_path=Path(args[2]);self.output_path=Path(args[3])
            self.output_path.write_text('{"text":"Camera 1 100 100","tables":[],"warnings":[],"engine":"PaddleOCR PP-StructureV3"}')
            return type('Run',(),{'returncode':0})()
        with patch('app.subprocess.run',side_effect=infer):
            response=TestClient(app.app).post('/scan',data={'company_id':'x'},files={'file':('bill.png',image.getvalue(),'image/png')})
        self.assertEqual(response.status_code,200)
        self.assertEqual(response.json()['text'],'Camera 1 100 100')
        self.assertFalse(self.input_path.exists());self.assertFalse(self.output_path.exists())

    @patch('app.httpx.Client')
    def test_nonmember_is_rejected(self, client):
        http=client.return_value.__enter__.return_value
        http.get.return_value.status_code=200
        http.post.return_value.status_code=200
        http.post.return_value.json.return_value=None
        with patch.dict('os.environ',{'SUPABASE_URL':'https://example.supabase.co','SUPABASE_ANON_KEY':'public-test'}):
            with self.assertRaises(app.HTTPException) as error: app.authorize('Bearer valid','00000000-0000-0000-0000-000000000001')
        self.assertEqual(error.exception.status_code,403)

    @patch('app.authorize')
    def test_busy_worker_rejects_second_scan(self, auth):
        app.slot.acquire()
        try:
            response=TestClient(app.app).post('/scan',data={'company_id':'x'},files={'file':('bill.png',b'x','image/png')})
            self.assertEqual(response.status_code,429)
        finally: app.slot.release()

    @patch('app.authorize')
    def test_timeout_releases_worker(self, auth):
        import subprocess
        image=io.BytesIO();Image.new('RGB',(20,20),'white').save(image,format='PNG')
        with patch('app.subprocess.run',side_effect=subprocess.TimeoutExpired('scan',240)):
            response=TestClient(app.app).post('/scan',data={'company_id':'x'},files={'file':('bill.png',image.getvalue(),'image/png')})
        self.assertEqual(response.status_code,504)
        self.assertTrue(app.slot.acquire(blocking=False))
        app.slot.release()

if __name__=='__main__':unittest.main()
