# GT7 Stats OBS Widget - Setup Instructions

## What is this?
A live Gran Turismo 7 stats overlay for OBS that displays your Driver Rating, Sportsmanship Rating, and race statistics on your stream.

## Features
- **Live DR & SR** - Automatically updates your ratings
- **Race Stats** - Shows total races, wins, poles, and fastest laps
- **Auto-refresh** - Updates every 30 seconds
- **Animated** - Smooth transitions and glow effects
- **Customizable** - Easy to change colors and styling

## Setup Instructions

### Step 1: Get Your User ID
1. Go to https://gtstats.live/
2. Search for your PSN ID
3. Look at the URL - it will show your user_id
   - Example: `https://gtstats.live/players/SparksTheory?user_id=85596fe8-f2f8-45c1-9474-f3357e8d9446`
   - Your User ID is: `85596fe8-f2f8-45c1-9474-f3357e8d9446`

### Step 2: Configure the Widget
1. Download `gt7-obs-widget.html`
2. Open it in a text editor (Notepad, VS Code, etc.)
3. Find the CONFIGURATION section (around line 154):
   ```javascript
   const CONFIG = {
       PSN_ID: 'YourPSNName',              // Change this!
       USER_ID: 'your-user-id-here',        // Change this!
       REFRESH_INTERVAL: 30000,             // 30 seconds
       USE_CORS_PROXY: true
   };
   ```
4. Replace `PSN_ID` with your PSN name
5. Replace `USER_ID` with your user ID from Step 1
6. Save the file

### Step 3: Add to OBS
1. In OBS, add a new **Browser** source
2. **Local file:** Check this box
3. **Browse** and select `gt7-obs-widget.html`
4. **Width:** 600
5. **Height:** 400
6. Check **"Shutdown source when not visible"** (saves CPU)
7. Click **OK**

### Step 4: Position & Customize
- Drag the widget to your desired position on stream
- Resize as needed (keep aspect ratio)
- The widget has a transparent background

## Customization

### Change Colors
Edit the CSS variables (lines 9-15):
```css
:root {
    --primary-color: #00ff88;      /* DR color */
    --secondary-color: #0ea5e9;    /* SR color */
    --bg-color: rgba(10, 14, 18, 0.95);
    --text-color: #ffffff;
}
```

### Change Refresh Rate
Edit line 156:
```javascript
REFRESH_INTERVAL: 30000,  // 30000 = 30 seconds, 60000 = 1 minute
```

### Make Background More/Less Transparent
Change line 11:
```css
--bg-color: rgba(10, 14, 18, 0.95);  /* Last number (0.95) = opacity */
```
- `1.0` = fully opaque
- `0.5` = 50% transparent
- `0.0` = fully transparent

## Troubleshooting

**Widget shows "Loading..."**
- Make sure your User ID and PSN ID are correct
- Check your internet connection
- Try refreshing the browser source in OBS

**Stats not updating**
- Check the "Last updated" timestamp at the bottom
- Verify you have recent Sport Mode races in GT7
- Try increasing the refresh interval if API is rate-limited

**Error message appears**
- Double-check your User ID matches your PSN account
- Make sure you've participated in GT7 Sport Mode recently
- Check the browser console in OBS for detailed errors

## Support

Need help? Contact via:
- Website: https://sparkstheory.co.uk
- Email: sparks@sparkstheory.co.uk
- Twitter: @SparksTheory

## Credits
Data provided by gtstats.live API
Widget created by SparksTheory
