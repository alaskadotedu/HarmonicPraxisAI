const fs = require('fs');
function recHeader(len, type, dataType) {
  const b = Buffer.alloc(4); b.writeUInt16BE(len, 0); b.writeUInt8(type, 2); b.writeUInt8(dataType, 3); return b;
}
function recInt16(type, vals) {
  const b = Buffer.alloc(4 + vals.length * 2); b.writeUInt16BE(b.length, 0); b.writeUInt8(type, 2); b.writeUInt8(0x02, 3);
  vals.forEach((v, i) => b.writeInt16BE(v, 4 + i * 2)); return b;
}
function recInt32(type, vals) {
  const b = Buffer.alloc(4 + vals.length * 4); b.writeUInt16BE(b.length, 0); b.writeUInt8(type, 2); b.writeUInt8(0x03, 3);
  vals.forEach((v, i) => b.writeInt32BE(v, 4 + i * 4)); return b;
}
function recAscii(type, str) {
  const raw = Buffer.from(str, 'ascii'); const paddedLen = raw.length % 2 === 0 ? raw.length : raw.length + 1;
  const b = Buffer.alloc(4 + paddedLen); b.writeUInt16BE(b.length, 0); b.writeUInt8(type, 2); b.writeUInt8(0x06, 3);
  raw.copy(b, 4); return b;
}
function float64ToGdsReal8(val) {
  const b = Buffer.alloc(8); if (val === 0) return b;
  let sign = 0; if (val < 0) { sign = 0x80; val = -val; }
  let exp = 64; while (val >= 1.0) { val /= 16.0; exp++; } while (val < 1.0 / 16.0) { val *= 16.0; exp--; }
  b.writeUInt8(sign | (exp & 0x7F), 0);
  let frac = val;
  for (let i = 1; i < 8; i++) { frac *= 256.0; const byte = Math.floor(frac); b.writeUInt8(byte, i); frac -= byte; }
  return b;
}
function recReal8(type, vals) {
  const chunks = [recHeader(4 + vals.length * 8, type, 0x05)];
  vals.forEach(v => chunks.push(float64ToGdsReal8(v))); return Buffer.concat(chunks);
}
const jsonPath = process.argv[2]; const gdsPath = process.argv[3];
const pkg = JSON.parse(fs.readFileSync(jsonPath, 'utf8'));
const now = new Date();
const ts = [now.getUTCFullYear() - 1900, now.getUTCMonth() + 1, now.getUTCDate(), now.getUTCHours(), now.getUTCMinutes(), now.getUTCSeconds(), now.getUTCFullYear() - 1900, now.getUTCMonth() + 1, now.getUTCDate(), now.getUTCHours(), now.getUTCMinutes(), now.getUTCSeconds()];
const records = [recInt16(0x00, [6]), recInt16(0x01, ts), recAscii(0x02, 'HARMONIC_PRAXIS_LIB'), recReal8(0x03, [0.001, 1e-12]), recInt16(0x05, ts), recAscii(0x06, pkg.material_profile.slice(0, 32))];
for (const cell of pkg.structures) {
  const flatXy = [];
  for (const pt of cell.gds_xy_dbu_pm) { flatXy.push(Math.round(pt[0]), Math.round(pt[1])); }
  records.push(recHeader(4, 0x08, 0x00), recInt16(0x0D, [cell.gds_layer]), recInt16(0x0E, [cell.gds_datatype]), recInt32(0x10, flatXy), recHeader(4, 0x11, 0x00));
}
records.push(recHeader(4, 0x07, 0x00), recHeader(4, 0x04, 0x00));
const finalBuf = Buffer.concat(records);
fs.writeFileSync(gdsPath, finalBuf);
console.log(JSON.stringify({ binaryGdsWritten: true, path: gdsPath, bytes: finalBuf.length, polygons: pkg.structures.length }));