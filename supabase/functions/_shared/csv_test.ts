import { assertEquals } from '@std/assert';
import { toCsv } from './csv.ts';

Deno.test('CSV: BOM·따옴표·쉼표 이스케이프', () => {
  assertEquals(toCsv([{ nickname: '지수', note: 'a,"b"', s_d: 28.8 }]), '﻿nickname,note,s_d\r\n지수,"a,""b""",28.8\r\n');
  assertEquals(toCsv([]), '﻿');
});
