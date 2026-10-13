# Agora Token Worker (Cloudflare)
1. Cloudflare Dashboard -> Workers & Pages -> Create -> Worker، سمّيه `fahmny-agora`، Deploy.
2. Edit code: الصق محتوى src/index.js بالكامل -> Deploy.
3. Settings -> Variables and Secrets:
   - Text: FIREBASE_PROJECT_ID = studio-7708799057-99672
   - Secret: AGORA_APP_ID
   - Secret: AGORA_APP_CERTIFICATE (من شهادة جديدة، انظر الملاحظة)
4. لو رابط الـ Worker مختلف عن https://fahmny-agora.mohamedragabewiess.workers.dev عدّل _defaultUrl في lib/services/agora_token_service.dart.
