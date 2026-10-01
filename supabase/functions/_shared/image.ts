// 업로드 객체 재검증용: 서버에서 SHA-256·바이트 수·해상도를 직접 잰다(05 §6, 클라이언트 보고값은 믿지 않음).
export async function sha256Bytes(b: Uint8Array): Promise<string> {
  const d = await crypto.subtle.digest('SHA-256', new Uint8Array(b)); // ArrayBuffer 기반 복사(SharedArrayBuffer 타입 배제)
  return [...new Uint8Array(d)].map((x) => x.toString(16).padStart(2, '0')).join('');
}

/** JPEG(SOFn)·PNG(IHDR) 헤더에서 가로·세로. 알 수 없는 형식이면 null. */
export function imageSize(b: Uint8Array): { width: number; height: number; type: 'jpeg' | 'png' } | null {
  if (b.length >= 24 && b[0] === 0x89 && b[1] === 0x50 && b[2] === 0x4e && b[3] === 0x47) {
    const v = new DataView(b.buffer, b.byteOffset, b.byteLength);
    return { width: v.getUint32(16), height: v.getUint32(20), type: 'png' };
  }
  if (b.length < 4 || b[0] !== 0xff || b[1] !== 0xd8) return null;
  let i = 2;
  while (i + 9 < b.length) {
    if (b[i] !== 0xff) { i++; continue; }
    const marker = b[i + 1];
    if (marker === 0xd8 || marker === 0x01 || (marker >= 0xd0 && marker <= 0xd7)) { i += 2; continue; }
    const len = (b[i + 2] << 8) | b[i + 3];
    // SOF0~SOF15 (DHT c4·JPG c8·DAC cc 제외)
    if (marker >= 0xc0 && marker <= 0xcf && marker !== 0xc4 && marker !== 0xc8 && marker !== 0xcc) {
      return { height: (b[i + 5] << 8) | b[i + 6], width: (b[i + 7] << 8) | b[i + 8], type: 'jpeg' };
    }
    if (marker === 0xda) return null; // 스캔 시작 전에 SOF 없음
    i += 2 + len;
  }
  return null;
}
