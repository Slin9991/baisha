# Villa website — GitHub Pages ready

A simple responsive single-page website with Home, Room Types and Contact Us. Plain HTML and CSS; no installation, build step, third-party scripts or server required.

## Replace the dummy text
Open `index.html` in any text editor. Replace the text inside square brackets, including the page title, description, villa name, room details, contact information and copyright year. Save and refresh. The fixed navigation labels are ready to use.

The supplied photographs depict the villa exterior and pool. Room cards therefore use exterior placeholder images. Replace their `src` values with actual room photos and update the `alt` descriptions before publishing room information. `photo-map.json` maps each optimized image to its uploaded filename. All ten uploaded photos are used; originals are unchanged.

Contact details are plain text placeholders. To make your real email clickable, use `<a href="mailto:you@example.com">you@example.com</a>`; phone links use `tel:+886...`. There is no booking or contact submission backend.

## Publish on GitHub Pages
1. Extract this ZIP and upload the contents of `villa-website` to the root of your GitHub repository. `index.html` must be at the repository root, not inside an extra folder.
2. Go to repository **Settings → Pages**.
3. Under **Build and deployment**, choose **Deploy from a branch**.
4. Select your branch (usually `main`), choose **/ (root)** and save.
5. Open the website URL displayed by GitHub once deployment completes.

All asset links are relative, so the website works at both a custom domain and a GitHub Pages repository subpath. `.nojekyll` disables Jekyll processing. Preview locally by opening `index.html`, or run `python3 -m http.server 8000` in this folder and visit http://localhost:8000.

## Files
- `index.html`: content and section structure
- `styles.css`: colors, typography and responsive layout
- `assets/`: optimized photographs with portable filenames
- `photo-map.json`: source filename reference

## English / Traditional Chinese
The header language button switches all text, image descriptions, accessibility labels, page title and description. Traditional Chinese is the default; the selected language is remembered in the visitor's browser when storage is available. If JavaScript is unavailable, Traditional Chinese remains readable.

To update content, edit BOTH `data-en="English text"` and `data-zh="繁體中文文字"` on the relevant element in `index.html`. Also update the text between the tags to match Traditional Chinese for the no-JavaScript fallback. For image descriptions, edit `data-en-alt`, `data-zh-alt` and `alt`. The visible placeholders remain in square brackets in both languages. This is manual bilingual content, not automatic translation.

Upload `index.html`, `styles.css` AND `language.js` to the repository root to install this update. Existing photos do not need to be uploaded again. Keep your GitHub workflow and domain settings.

The brand is Baisha36 in both languages. The location is Kenting / 墾丁. HTML uses indented lines, section comments, and separate data-en / data-zh attributes for easy editing. Returning visitors retain their previously selected language.
