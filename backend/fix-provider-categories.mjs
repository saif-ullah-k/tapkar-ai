// One-shot: normalize the `category` field on every real provider doc
// so it matches the taxonomy ids that customer-side discovery filters on.
// "Plumber" → "plumber", "AC Tech" → "ac_technician", etc.
import { Firestore } from '@google-cloud/firestore';

const fs = new Firestore({ projectId: process.env.GCP_PROJECT || 'fcmapp-30770' });

function normalize(raw) {
  if (!raw) return 'general';
  let v = String(raw).split(',')[0].trim().toLowerCase();
  v = v.replace(/[-\s]+/g, '_').replace(/[^a-z0-9_]/g, '');
  const aliases = {
    ac: 'ac_technician', ac_tech: 'ac_technician', ac_repair: 'ac_technician',
    ac_wala: 'ac_technician', aircon: 'ac_technician',
    plumbing: 'plumber', pipe_fitter: 'plumber', nalsaaz: 'plumber',
    electric: 'electrician', electrical: 'electrician',
    tuition: 'tutor', teacher: 'tutor',
    quran: 'quran_teacher',
    beauty: 'beautician', mehndi: 'mehndi_artist', mehendi: 'mehndi_artist',
  };
  return aliases[v] ?? v;
}

const snap = await fs.collection('providers').get();
const real = snap.docs.filter((d) => d.id.startsWith('p_user_'));
console.log(`Inspecting ${real.length} real provider doc(s)...`);
let changed = 0;
for (const d of real) {
  const data = d.data();
  const oldCat = data.category;
  const newCat = normalize(oldCat);
  if (oldCat !== newCat) {
    await d.ref.update({ category: newCat });
    console.log(`  ${d.id}: ${oldCat} → ${newCat} ✓`);
    changed++;
  } else {
    console.log(`  ${d.id}: ${oldCat} (already canonical)`);
  }
}
console.log(`\nFixed ${changed}/${real.length}`);
