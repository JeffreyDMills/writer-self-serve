// Vercel serverless function — proxies a campaign request to the Writer playbook webhook.
//
// The Writer Bearer token NEVER ships to the browser. It lives only here, read from
// the CAMPAIGN_API_KEY environment variable set in Vercel (Project → Settings → Environment Variables).
// (Named generically so a failed run never reveals the backend vendor in the UI.)
//
// The browser sends JSON: { keyword, filename, fileBase64 }.
// This function rebuilds the multipart upload Writer expects (a "data" JSON field plus a
// "files" part) and forwards it with the Authorization header attached server-side.
//
// Returns Writer's trigger response verbatim so the frontend can read the session reference.

export const config = {
  runtime: 'nodejs',
  maxDuration: 60, // Pro plan. Trigger returns fast; raise toward 300 only if Writer blocks.
};

const WRITER_URL =
  'https://app.writer.com/webhook/triggers/playbook/a73fdf7f-b4a5-4434-a565-431fcd4ad3cb';

export default async function handler(req, res) {
  // CORS — allow the deployed frontend (same origin) and any tab during demos.
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');
  res.setHeader('Access-Control-Max-Age', '600');

  if (req.method === 'OPTIONS') return res.status(204).end();
  if (req.method !== 'POST') return res.status(405).json({ error: 'Method not allowed' });

  const token = process.env.CAMPAIGN_API_KEY;
  if (!token) {
    return res
      .status(500)
      .json({ error: 'Server misconfigured: CAMPAIGN_API_KEY not set in Vercel env vars' });
  }

  const body = req.body || {};
  let { keyword, filename, fileBase64, email } = body;

  if (!keyword || !filename || !fileBase64) {
    return res
      .status(400)
      .json({ error: 'Missing one of: keyword, filename, fileBase64' });
  }

  // Strip a data-URL prefix if the browser sent one (data:...;base64,XXXX).
  const comma = fileBase64.indexOf(',');
  if (fileBase64.startsWith('data:') && comma !== -1) {
    fileBase64 = fileBase64.slice(comma + 1);
  }

  try {
    const buffer = Buffer.from(fileBase64, 'base64');

    // Match the playbook's expected input contract exactly.
    // Recipient_Email is passed through so the playbook can email the finished
    // deliverables to the lead. Requires a matching "Recipient_Email" input
    // (and a send step) to exist in the playbook; harmless if the playbook
    // ignores unknown inputs.
    const inputs = [
      { id: 'Product_Excel_File', value: ['file:' + filename] },
      { id: 'Target_Keyword', value: [keyword] },
    ];
    if (email) {
      inputs.push({ id: 'recipientemail', value: [String(email)] });
    }
    const data = { inputs };

    const form = new FormData();
    form.append('data', JSON.stringify(data));
    form.append(
      'files',
      new Blob([buffer], {
        type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      }),
      filename
    );

    const upstream = await fetch(WRITER_URL, {
      method: 'POST',
      headers: { Authorization: 'Bearer ' + token },
      body: form,
    });

    const text = await upstream.text();
    res.status(upstream.status);
    res.setHeader('Content-Type', upstream.headers.get('content-type') || 'application/json');
    return res.send(text);
  } catch (e) {
    return res
      .status(502)
      .json({ error: 'Upstream error: ' + ((e && e.message) || String(e)) });
  }
}
