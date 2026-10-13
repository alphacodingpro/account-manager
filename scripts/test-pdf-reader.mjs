import assert from 'node:assert/strict';
import {getDocument,version} from 'pdfjs-dist/legacy/build/pdf.mjs';
const content='BT /F1 12 Tf 50 750 Td (Invoice test line Quantity 2 Amount 100) Tj ET';
const objects=['<< /Type /Catalog /Pages 2 0 R >>','<< /Type /Pages /Kids [3 0 R] /Count 1 >>','<< /Type /Page /Parent 2 0 R /MediaBox [0 0 600 800] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>','<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',`<< /Length ${content.length} >>\nstream\n${content}\nendstream`];
let pdf='%PDF-1.4\n';const offsets=[0];for(const [i,obj] of objects.entries()){offsets.push(Buffer.byteLength(pdf));pdf+=`${i+1} 0 obj\n${obj}\nendobj\n`;}
const xref=Buffer.byteLength(pdf);pdf+=`xref\n0 6\n0000000000 65535 f \n${offsets.slice(1).map(n=>String(n).padStart(10,'0')+' 00000 n ').join('\n')}\ntrailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n${xref}\n%%EOF`;
const task=getDocument({data:new Uint8Array(Buffer.from(pdf))});try{const doc=await task.promise;assert.equal(doc.numPages,1);const page=await doc.getPage(1);const text=(await page.getTextContent()).items.filter(x=>'str' in x).map(x=>x.str).join(' ');assert.match(text,/Quantity 2 Amount 100/);}finally{await task.destroy();}console.log(`PDF reader ${version}: native text extraction and worker cleanup passed.`);
