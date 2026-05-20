import { Firestore } from '@google-cloud/firestore';

const DATABASES = [
  '(default)',
  'ai-studio-dbc4eb6d-e552-4610-92c4-479976f46a36',
  'ai-studio-6931fac1-1e31-49d1-9950-c65f84485d34',
];

for (const databaseId of DATABASES) {
  const fs = new Firestore({ projectId: 'fcmapp-30770', databaseId });
  try {
    const snap = await fs.collection('providers').get();
    const real = snap.docs.filter((d) => d.id.startsWith('p_user_'));
    console.log(`DB ${databaseId.padEnd(50)} providers=${snap.size}  real=${real.length}`);
    for (const d of real) {
      const data = d.data();
      console.log(`     ${d.id}  ${data.name}  ${data.category}  ${data.neighborhood}`);
    }
  } catch (e) {
    console.log(`DB ${databaseId.padEnd(50)} ERR ${e.message?.slice(0, 60)}`);
  }
}
