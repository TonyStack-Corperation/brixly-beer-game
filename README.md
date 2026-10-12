# Brixly Beer Game

Static single-page app (`index.html`) backed by Supabase (`supabase_setup.sql`).
Setup guide (Thai): [SETUP-TH.md](SETUP-TH.md)

## Deploy to Vercel
1. Import this repo in Vercel (Framework Preset: **Other**, no build command, output = root).
2. Create a Supabase project, run `supabase_setup.sql` in the SQL Editor.
3. Put Project URL and anon key into `SUPABASE_URL` / `SUPABASE_ANON_KEY` in `index.html`, commit, push. Vercel redeploys automatically.
