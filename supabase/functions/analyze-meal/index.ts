// POST /functions/v1/analyze-meal {meal_id}
// POST F:/meals 가 끼니(captured, engine=gemini)를 만든 뒤 호출한다(overseas_ai 동의자만).
// service_role 전용: Authorization 에 service_role 키 또는 x-internal-secret(INTERNAL_SECRET).
import { analyzeMeal, type AnalyzeDeps, type FoodMatch } from '../_shared/analyze.ts';
import { selectAdapter } from '../_shared/ai/select.ts';
import { handle, HttpError, json } from '../_shared/http.ts';
import { selectPushSender, sendNow } from '../_shared/push.ts';
import { env, serviceClient } from '../_shared/supabase.ts';

const BUCKET = 'meal-photos';

Deno.serve((req) =>
  handle(req, async (req) => {
    if (req.method !== 'POST') throw new HttpError(405, 'POST only');
    const secret = env('INTERNAL_SECRET');
    if (!secret || req.headers.get('x-internal-secret') !== secret) throw new HttpError(403, 'internal only');
    const { meal_id } = await req.json();
    if (typeof meal_id !== 'string') throw new HttpError(422, 'meal_id');
    const db = serviceClient();

    const { data: meal, error } = await db.from('meals')
      .select('id, status, engine, participant_id, local_date, photo_id, slot, participants(user_id, challenge_id), photos(storage_path)')
      .eq('id', meal_id).single();
    if (error || !meal) throw new HttpError(404, 'meal not found');
    if (meal.status !== 'captured' || meal.engine === 'none') return json({ skipped: true, status: meal.status });
    // deno-lint-ignore no-explicit-any
    const part = meal.participants as any, photo = meal.photos as any;

    const deps: AnalyzeDeps = {
      adapter: selectAdapter(env),
      async loadImage() {
        const { data, error } = await db.storage.from(BUCKET).download(photo.storage_path);
        if (error || !data) throw new HttpError(422, 'photo object missing');
        return { bytes: new Uint8Array(await data.arrayBuffer()), mimeType: 'image/jpeg' };
      },
      async mapFood(candidates, packaged = false) {
        // 포장 상품은 가공식품(상품) 행 먼저, 아니면 음식 행만(D63)
        const { data, error } = await db.rpc('map_food_candidates', { p_candidates: candidates, p_packaged: packaged });
        if (error) throw error;
        return data as FoodMatch;
      },
      async saveDraft(id, r) {
        if (r.items.length) {
          const { error } = await db.from('meal_items').insert(r.items.map((it) => ({
            meal_id: id, name_candidates: it.name_candidates, chosen_name: it.chosen_name, food_code: it.food_code,
            input_type: 'ai', count: it.count, portion_bucket: it.portion_bucket, portion_multiplier: it.portion_multiplier,
            confidence: it.confidence, match_score: it.match_score, needs_check: it.needs_check, ai_kcal: it.ai_kcal,
            has_broth: it.has_broth, serving_kcal: it.serving_kcal, candidate_kcal: it.candidate_kcal,
            candidate_food_codes: it.candidate_food_codes,
          })));
          if (error) throw error;
        }
        const engine = r.engine === 'mock' ? 'gemini' : r.engine;
        const { error: e2 } = await db.from('meals').update({ status: r.status, ai_kcal: r.ai_kcal, engine }).eq('id', id);
        if (e2) throw e2;
        // 초안은 잠정 점수에 max(M, 1.3×AI)로 산입되므로 바로 재계산
        const { error: e3 } = await db.rpc('recompute_day', { p_participant: meal.participant_id, p_date: meal.local_date });
        if (e3) throw e3;
      },
      async notify(id, kind) {
        const slot = { breakfast: '아침', lunch: '점심', dinner: '저녁', snack: '간식' }[meal.slot as string] ?? '식사';
        // N-04 (transactional): 끼니당 1건, 재분석 시 미발송
        const { count } = await db.from('notifications').select('id', { count: 'exact', head: true })
          .eq('user_id', part.user_id).eq('type', 'N-04').contains('payload', { meal_id: id });
        if (count) return;
        const { data: nid, error: e4 } = await db.rpc('enqueue_notification', {
          p_user: part.user_id, p_challenge: part.challenge_id, p_type: 'N-04', p_title: '분석 완료',
          p_body: kind === 'done' ? `${slot} 분석이 끝났어요. 확인하고 확정해 주세요` : '음식을 찾지 못했어요. 검색으로 확정해 주세요',
          p_payload: { meal_id: id, slot: meal.slot },
        });
        if (e4 || !nid) return;
        // transactional: 워커 주기(1~5분)를 기다리지 않고 바로 보낸다. 토큰 없음·권한 미허용이면 no_push 로 남고 앱이 홈에서 다시 읽는다.
        await sendNow(db, [nid as string], selectPushSender(env));
      },
    };
    const out = await analyzeMeal(meal_id, deps);
    return json(out);
  })
);
