from pathlib import Path

path = Path('supabase/functions/whatsapp-webhook/index.ts')
text = path.read_text()
old = '  const fallbackMessage = payload?.body || payload?.data?.body || payload?.text?.body || payload?.text || "";\n'
new = '''  const fallbackMessage =\n    typeof payload?.body === "string" ? payload.body :\n    typeof payload?.data?.body === "string" ? payload.data.body :\n    typeof payload?.text?.body === "string" ? payload.text.body :\n    typeof payload?.text === "string" ? payload.text :\n    typeof payload?.message === "string" ? payload.message :\n    "";\n'''
if old not in text:
    raise SystemExit('fallback line not found')
path.write_text(text.replace(old, new, 1))
