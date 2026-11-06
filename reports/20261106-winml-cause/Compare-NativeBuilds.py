"""Compare the tested and rebuilt DLL sections, excluding linker timestamps."""
import hashlib
import json
from pathlib import Path
import struct

root=Path(__file__).resolve().parent
records=json.loads((root/'native-builds.json').read_text(encoding='utf-8-sig'))
sections=[];raw_sections=[];timestamps=[]
for record in records:
    data=bytearray(Path(record['Dll']).read_bytes())
    pe=struct.unpack_from('<I',data,60)[0]
    if data[:2]!=b'MZ' or data[pe:pe+4]!=b'PE\0\0' or struct.unpack_from('<H',data,pe+24)[0]!=0x20b:
        raise ValueError('Expected a PE32+ DLL')
    count=struct.unpack_from('<H',data,pe+6)[0];optional_size=struct.unpack_from('<H',data,pe+20)[0]
    export_rva=struct.unpack_from('<I',data,pe+24+112)[0]
    entries=[]
    for index in range(count):
        position=pe+24+optional_size+index*40
        name=data[position:position+8].rstrip(b'\0').decode()
        virtual_size,rva,length,offset=struct.unpack_from('<IIII',data,position+8)
        entries.append((name,rva,virtual_size,length,offset))
    raw_sections.append({name:hashlib.sha256(data[offset:offset+length]).hexdigest() for name,rva,size,length,offset in entries})
    owner=next(entry for entry in entries if entry[1]<=export_rva<entry[1]+entry[2])
    timestamp_offset=owner[4]+export_rva-owner[1]+4
    timestamps.append(struct.unpack_from('<I',data,timestamp_offset)[0])
    data[timestamp_offset:timestamp_offset+4]=b'\0'*4
    debug_rva,debug_size=struct.unpack_from('<II',data,pe+24+112+6*8)
    if debug_rva:
        debug_owner=next(entry for entry in entries if entry[1]<=debug_rva<entry[1]+entry[2])
        debug_offset=debug_owner[4]+debug_rva-debug_owner[1]
        for index in range(debug_size//28):
            data[debug_offset+index*28+4:debug_offset+index*28+8]=b'\0'*4
    sections.append({name:hashlib.sha256(data[offset:offset+length]).hexdigest() for name,rva,size,length,offset in entries})
result=dict(normalized_sections_identical=sections[0]==sections[1],raw_sections_identical=raw_sections[0]==raw_sections[1],
            excluded_field='IMAGE_EXPORT_DIRECTORY.TimeDateStamp and IMAGE_DEBUG_DIRECTORY.TimeDateStamp',export_timestamps=timestamps,
            section_hashes=sections,builds=records)
(root/'native-section-comparison.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
print(json.dumps(dict(normalized_sections_identical=result['normalized_sections_identical'],excluded_field=result['excluded_field'])))
if not result['normalized_sections_identical']:raise SystemExit(1)
