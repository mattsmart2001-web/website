// ===== SUPABASE CONFIGURATION =====
const SUPABASE_URL = 'https://vcdrzlyyjsskiyqydads.supabase.co';
const SUPABASE_ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InZjZHJ6bHl5anNza2l5cXlkYWRzIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NjY2NTEyOTAsImV4cCI6MjA4MjIyNzI5MH0.SqSizMAETa8KJyrwgWC7shpz19u__QWwQyAMYF_UpJs';
const supabaseClient = window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);

// ===== UTILITY FUNCTIONS =====

// Convert country code to flag emoji
function getCountryFlag(countryCode) {
    if (!countryCode) return '';
    const codePoints = countryCode
        .toUpperCase()
        .split('')
        .map(char => 127397 + char.charCodeAt());
    return String.fromCodePoint(...codePoints);
}

// Animate number counting up
function animateCounter(element, start, end, duration = 1000, decimals = 0, suffix = '') {
    if (!element) return;

    const startTime = performance.now();
    const range = end - start;

    function update(currentTime) {
        const elapsed = currentTime - startTime;
        const progress = Math.min(elapsed / duration, 1);

        // Easing function (easeOutQuad)
        const easeProgress = 1 - Math.pow(1 - progress, 3);

        const current = start + (range * easeProgress);
        element.textContent = current.toFixed(decimals) + suffix;

        if (progress < 1) {
            requestAnimationFrame(update);
        } else {
            element.textContent = end.toFixed(decimals) + suffix;
        }
    }

    requestAnimationFrame(update);
}

// Animate multiple counters with stagger effect
function animateCounters(selector, duration = 1000) {
    const elements = document.querySelectorAll(selector);
    elements.forEach((el, index) => {
        const target = parseFloat(el.dataset.target || el.textContent.replace(/[^0-9.-]/g, ''));
        const decimals = parseInt(el.dataset.decimals || 0);
        const suffix = el.dataset.suffix || '';

        // Stagger start time
        setTimeout(() => {
            animateCounter(el, 0, target, duration, decimals, suffix);
        }, index * 50);
    });
}

// ===== PLAYER NOTES & TAGS =====

// Available tags
const PLAYER_TAGS = [
    { id: 'rival', label: 'Rival', icon: '🏁', color: '#ef4444' },
    { id: 'friend', label: 'Friend', icon: '👥', color: '#00ff88' },
    { id: 'clean', label: 'Clean Racer', icon: '🤝', color: '#0ea5e9' },
    { id: 'dirty', label: 'Dirty Driver', icon: '⚠️', color: '#f59e0b' },
    { id: 'discord', label: 'Discord', icon: '💬', color: '#5865f2' },
    { id: 'learning', label: 'Learning From', icon: '🎓', color: '#8b5cf6' }
];

// Get player notes from localStorage
function getPlayerNote(userGuid) {
    try {
        const notes = JSON.parse(localStorage.getItem('player_notes') || '{}');
        return notes[userGuid] || null;
    } catch (error) {
        console.error('Error getting player note:', error);
        return null;
    }
}

// Save player note to localStorage
function savePlayerNote(userGuid, note, tags) {
    try {
        const notes = JSON.parse(localStorage.getItem('player_notes') || '{}');
        if (!note && (!tags || tags.length === 0)) {
            // Remove note if both note and tags are empty
            delete notes[userGuid];
        } else {
            notes[userGuid] = { note, tags, updated: Date.now() };
        }
        localStorage.setItem('player_notes', JSON.stringify(notes));
    } catch (error) {
        console.error('Error saving player note:', error);
    }
}

// Show note editor modal
function showNoteEditor(player) {
    const existingNote = getPlayerNote(player.user_guid);
    const currentNote = existingNote?.note || '';
    const currentTags = existingNote?.tags || [];

    const modalId = `note-editor-${Date.now()}`;

    let html = `
        <div id="${modalId}" style="position: fixed; top: 0; left: 0; right: 0; bottom: 0; background: rgba(0,0,0,0.85); display: flex; align-items: center; justify-content: center; z-index: 10000; padding: 1rem;" onclick="this.remove()">
            <div style="background: linear-gradient(135deg, #1a1a2e 0%, #16213e 100%); border: 2px solid rgba(0,255,136,0.3); border-radius: 16px; max-width: 500px; width: 100%; padding: 2rem;" onclick="event.stopPropagation()">
                <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 1.5rem;">
                    <h3 style="color: var(--color-primary); font-size: 1.3rem; margin: 0;">📝 Notes for ${player.psn_id}</h3>
                    <button onclick="document.getElementById('${modalId}').remove()" style="background: rgba(255,255,255,0.1); border: 1px solid rgba(255,255,255,0.2); color: white; padding: 0.4rem 0.8rem; border-radius: 8px; cursor: pointer; font-size: 0.9rem; transition: all 0.2s;" onmouseover="this.style.background='rgba(255,255,255,0.2)'" onmouseout="this.style.background='rgba(255,255,255,0.1)'">Close</button>
                </div>

                <div style="margin-bottom: 1.5rem;">
                    <label style="display: block; color: var(--color-text-muted); font-size: 0.85rem; margin-bottom: 0.5rem; text-transform: uppercase; letter-spacing: 1px;">Personal Note</label>
                    <textarea id="noteText" placeholder="Add your personal notes about this driver..." style="width: 100%; min-height: 100px; background: rgba(255,255,255,0.05); border: 1px solid rgba(255,255,255,0.1); border-radius: 8px; padding: 0.75rem; color: var(--color-text); font-family: var(--font-primary); font-size: 0.95rem; resize: vertical;" onmouseover="this.style.borderColor='rgba(0,255,136,0.3)'" onmouseout="this.style.borderColor='rgba(255,255,255,0.1)'">${currentNote}</textarea>
                </div>

                <div style="margin-bottom: 1.5rem;">
                    <label style="display: block; color: var(--color-text-muted); font-size: 0.85rem; margin-bottom: 0.75rem; text-transform: uppercase; letter-spacing: 1px;">Quick Tags</label>
                    <div style="display: grid; grid-template-columns: repeat(2, 1fr); gap: 0.5rem;" id="tagSelector">
    `;

    PLAYER_TAGS.forEach(tag => {
        const isSelected = currentTags.includes(tag.id);
        html += `
            <button
                data-tag="${tag.id}"
                onclick="toggleTag(this)"
                style="background: ${isSelected ? tag.color + '40' : 'rgba(255,255,255,0.05)'}; border: 2px solid ${isSelected ? tag.color : 'rgba(255,255,255,0.1)'}; color: ${isSelected ? tag.color : 'var(--color-text-muted)'}; padding: 0.6rem; border-radius: 8px; cursor: pointer; font-size: 0.9rem; font-weight: 600; transition: all 0.2s; display: flex; align-items: center; gap: 0.5rem;"
                onmouseover="if(!this.dataset.selected) { this.style.background='rgba(255,255,255,0.1)'; this.style.borderColor='${tag.color}'; }"
                onmouseout="if(!this.dataset.selected) { this.style.background='rgba(255,255,255,0.05)'; this.style.borderColor='rgba(255,255,255,0.1)'; }"
            >
                <span style="font-size: 1.2rem;">${tag.icon}</span>
                <span>${tag.label}</span>
            </button>
        `;
    });

    html += `
                    </div>
                </div>

                <div style="display: flex; gap: 0.75rem;">
                    <button onclick="saveNote('${player.user_guid}', '${modalId}')" style="flex: 1; background: linear-gradient(135deg, rgba(0,255,136,0.2), rgba(14,165,233,0.2)); border: 2px solid rgba(0,255,136,0.5); color: var(--color-primary); padding: 0.75rem; border-radius: 8px; cursor: pointer; font-size: 1rem; font-weight: 700; transition: all 0.2s;" onmouseover="this.style.background='linear-gradient(135deg, rgba(0,255,136,0.3), rgba(14,165,233,0.3))'" onmouseout="this.style.background='linear-gradient(135deg, rgba(0,255,136,0.2), rgba(14,165,233,0.2))'">💾 Save Note</button>
                    <button onclick="deleteNote('${player.user_guid}', '${modalId}')" style="background: rgba(239,68,68,0.2); border: 2px solid rgba(239,68,68,0.5); color: #ef4444; padding: 0.75rem 1.25rem; border-radius: 8px; cursor: pointer; font-size: 1rem; font-weight: 700; transition: all 0.2s;" onmouseover="this.style.background='rgba(239,68,68,0.3)'" onmouseout="this.style.background='rgba(239,68,68,0.2)'">🗑️ Delete</button>
                </div>
            </div>
        </div>
    `;

    document.body.insertAdjacentHTML('beforeend', html);

    // Mark selected tags
    currentTags.forEach(tagId => {
        const btn = document.querySelector(`[data-tag="${tagId}"]`);
        if (btn) btn.dataset.selected = 'true';
    });
}

// Toggle tag selection
function toggleTag(button) {
    const isSelected = button.dataset.selected === 'true';
    const tag = PLAYER_TAGS.find(t => t.id === button.dataset.tag);

    if (isSelected) {
        button.dataset.selected = 'false';
        button.style.background = 'rgba(255,255,255,0.05)';
        button.style.borderColor = 'rgba(255,255,255,0.1)';
        button.style.color = 'var(--color-text-muted)';
    } else {
        button.dataset.selected = 'true';
        button.style.background = tag.color + '40';
        button.style.borderColor = tag.color;
        button.style.color = tag.color;
    }
}

// Save note from modal
function saveNote(userGuid, modalId) {
    const noteText = document.getElementById('noteText').value.trim();
    const selectedTags = Array.from(document.querySelectorAll('[data-tag][data-selected="true"]'))
        .map(btn => btn.dataset.tag);

    savePlayerNote(userGuid, noteText, selectedTags);
    document.getElementById(modalId).remove();

    // Refresh leaderboard to show updated tags
    displayLeaderboard();
}

// Delete note from modal
function deleteNote(userGuid, modalId) {
    if (confirm('Delete all notes and tags for this player?')) {
        savePlayerNote(userGuid, '', []);
        document.getElementById(modalId).remove();
        displayLeaderboard();
    }
}

// Get tags display HTML
function getTagsHTML(userGuid) {
    const noteData = getPlayerNote(userGuid);
    if (!noteData || (!noteData.tags || noteData.tags.length === 0)) {
        return '';
    }

    let html = '';
    noteData.tags.forEach(tagId => {
        const tag = PLAYER_TAGS.find(t => t.id === tagId);
        if (tag) {
            const tooltip = noteData.note ? `${tag.label} - ${noteData.note}` : tag.label;
            html += `<span style="background: ${tag.color}20; border: 1px solid ${tag.color}80; color: ${tag.color}; padding: 0.1rem 0.35rem; border-radius: 10px; font-size: 0.65rem; font-weight: 600; white-space: nowrap;" title="${tooltip}">${tag.icon}</span>`;
        }
    });
    return html;
}

// ===== THREE.JS 3D MODEL BACKGROUND =====
const scene = new THREE.Scene();
scene.background = null; // Transparent background

// Camera setup
const camera = new THREE.PerspectiveCamera(
    75,
    window.innerWidth / window.innerHeight,
    0.1,
    1000
);
camera.position.set(0, 1, 15); // Moved camera further back

// Renderer setup
const renderer = new THREE.WebGLRenderer({
    antialias: true,
    alpha: true
});
renderer.setSize(window.innerWidth, window.innerHeight);
renderer.setPixelRatio(window.devicePixelRatio);
renderer.setClearColor(0x000000, 0); // Transparent
document.getElementById('canvas-container').appendChild(renderer.domElement);

// Create environment with logo for reflections
const canvas = document.createElement('canvas');
canvas.width = 1024;
canvas.height = 512;
const ctx = canvas.getContext('2d');

let envTexture;
let envReady = false;

// Load logo and create environment
const logoImage = new Image();
logoImage.crossOrigin = 'anonymous';
logoImage.onload = function() {
    console.log('Logo image loaded, creating environment...');

    // Fill with dark background first
    ctx.fillStyle = '#0a0e12';
    ctx.fillRect(0, 0, 1024, 512);

    // Draw one large centered logo
    ctx.globalCompositeOperation = 'source-over';
    ctx.globalAlpha = 1.0; // Full opacity

    // Single large logo - offset to center reflection on angled glasses
    const logoSize = 500; // Smaller for cleaner reflection
    const centerX = (1024 - logoSize) / 2 + 180; // Shift right to center on both lenses
    const centerY = (512 - logoSize) / 2;
    ctx.drawImage(logoImage, centerX, centerY, logoSize, logoSize);

    // Add subtle blue tint overlay for brand colors
    ctx.globalCompositeOperation = 'overlay';
    ctx.globalAlpha = 0.2; // Even more subtle
    const gradient = ctx.createLinearGradient(0, 0, 0, 512);
    gradient.addColorStop(0, '#0ea5e9');
    gradient.addColorStop(1, '#38bdf8');
    ctx.fillStyle = gradient;
    ctx.fillRect(0, 0, 1024, 512);

    // Create environment texture
    envTexture = new THREE.CanvasTexture(canvas);
    envTexture.mapping = THREE.EquirectangularReflectionMapping;
    envTexture.needsUpdate = true;
    scene.environment = envTexture;
    envReady = true;

    console.log('Logo environment created and applied successfully');

    // Update model materials if model already loaded
    if (model) {
        updateModelMaterials();
    }
};
logoImage.onerror = function() {
    console.warn('Logo failed to load, using gradient only');
    // Fallback to gradient only
    const gradient = ctx.createLinearGradient(0, 0, 0, 512);
    gradient.addColorStop(0, '#0ea5e9');
    gradient.addColorStop(0.5, '#38bdf8');
    gradient.addColorStop(1, '#000000');
    ctx.fillStyle = gradient;
    ctx.fillRect(0, 0, 1024, 512);

    envTexture = new THREE.CanvasTexture(canvas);
    envTexture.mapping = THREE.EquirectangularReflectionMapping;
    scene.environment = envTexture;
    envReady = true;

    if (model) {
        updateModelMaterials();
    }
};
logoImage.src = 'sparks_logo.jpg';

// Function to update model materials with environment map
function updateModelMaterials() {
    if (!model || !envTexture) return;

    console.log('Updating model materials with environment map...');
    let materialCount = 0;

    model.traverse((child) => {
        if (child.isMesh && child.material) {
            materialCount++;
            const mat = child.material;
            const matName = mat.name ? mat.name.toLowerCase() : '';

            console.log('Material name:', mat.name, 'Has transmission:', mat.transmission);

            // Apply environment map to all materials
            mat.envMap = envTexture;

            // Check if this is a lens (usually has transmission or has "lens" in name)
            // Make sure nose pads, bridge, and supports are NOT treated as lenses
            const isLens = (mat.transmission > 0 || matName.includes('lens') || matName.includes('glass'))
                && !matName.includes('nose')
                && !matName.includes('pad')
                && !matName.includes('bridge')
                && !matName.includes('support');

            if (isLens) {
                // Lenses - reflective with logo, maintain transparency
                mat.envMapIntensity = 5.0; // Very strong reflection for high reflectivity
                mat.metalness = 0.2; // Slightly higher metalness for more reflection
                mat.roughness = 0.001; // Nearly mirror-smooth for maximum reflections
                if (mat.transmission !== undefined) {
                    mat.transmission = 0.9; // Keep transparency
                }
                console.log('  -> Configured as LENS (reflective with logo)');
            } else {
                // Frames - chrome/metallic
                mat.envMapIntensity = 4.0; // High reflection for chrome
                mat.metalness = 1.0; // Full metallic for chrome
                mat.roughness = 0.001; // Mirror-smooth for maximum chrome reflections
                console.log('  -> Configured as FRAME (chrome)');
            }

            mat.needsUpdate = true;
        }
    });

    console.log(`Updated ${materialCount} materials with environment map`);
}

// Lighting - much brighter for better sunglasses visibility
const ambientLight = new THREE.AmbientLight(0xffffff, 2.0); // Even brighter ambient
scene.add(ambientLight);

const mainLight = new THREE.DirectionalLight(0xffffff, 1.8); // Much brighter main
mainLight.position.set(5, 10, 5);
scene.add(mainLight);

const backLight = new THREE.DirectionalLight(0xffffff, 1.2); // Brighter back light
backLight.position.set(-5, 5, -5);
scene.add(backLight);

const fillLight = new THREE.DirectionalLight(0xffffff, 1.0); // Brighter fill
fillLight.position.set(0, -5, 0);
scene.add(fillLight);

// Additional front light for chrome reflections
const frontLight = new THREE.DirectionalLight(0xffffff, 1.2); // Brighter front
frontLight.position.set(0, 0, 10);
scene.add(frontLight);

// Additional side lights for better coverage
const leftLight = new THREE.DirectionalLight(0xffffff, 0.8);
leftLight.position.set(-10, 0, 5);
scene.add(leftLight);

const rightLight = new THREE.DirectionalLight(0xffffff, 0.8);
rightLight.position.set(10, 0, 5);
scene.add(rightLight);

// Dynamic mouse spotlight
const mouseLight = new THREE.SpotLight(0xffffff, 4); // Even brighter spotlight
mouseLight.position.set(0, 0, 10);
mouseLight.angle = Math.PI / 6;
mouseLight.penumbra = 0.3;
mouseLight.decay = 2;
mouseLight.distance = 50;
scene.add(mouseLight);

// ===== PARTICLE NETWORK BACKGROUND =====
const particleCount = 400; // Much more particles
const particlePositions = [];
const particleGeometry = new THREE.BufferGeometry();
const particleMaterial = new THREE.PointsMaterial({
    color: 0x0ea5e9,
    size: 0.4, // Even larger particles
    transparent: true,
    opacity: 0.75, // More prominent
    blending: THREE.AdditiveBlending,
    sizeAttenuation: true // Particles get bigger as they approach
});

// Create particles in 3D space with wider distribution
const positions = new Float32Array(particleCount * 3);
for (let i = 0; i < particleCount; i++) {
    const x = (Math.random() - 0.5) * 100; // Even wider spread
    const y = (Math.random() - 0.5) * 100; // Even wider spread
    const z = (Math.random() - 0.5) * 60 - 30; // Deep background to behind glasses

    positions[i * 3] = x;
    positions[i * 3 + 1] = y;
    positions[i * 3 + 2] = z;

    particlePositions.push(new THREE.Vector3(x, y, z));
}

particleGeometry.setAttribute('position', new THREE.BufferAttribute(positions, 3));
const particles = new THREE.Points(particleGeometry, particleMaterial);
scene.add(particles);

// Create lines connecting nearby particles
const lineMaterial = new THREE.LineBasicMaterial({
    color: 0x0ea5e9,
    transparent: true,
    opacity: 0.5, // Even more prominent lines
    blending: THREE.AdditiveBlending
});

const lineGeometry = new THREE.BufferGeometry();
const linePositions = [];
const maxDistance = 12; // Longer connections for denser network

function updateParticleLines() {
    linePositions.length = 0;

    for (let i = 0; i < particlePositions.length; i++) {
        for (let j = i + 1; j < particlePositions.length; j++) {
            const distance = particlePositions[i].distanceTo(particlePositions[j]);
            if (distance < maxDistance) {
                linePositions.push(
                    particlePositions[i].x, particlePositions[i].y, particlePositions[i].z,
                    particlePositions[j].x, particlePositions[j].y, particlePositions[j].z
                );
            }
        }
    }

    lineGeometry.setAttribute('position', new THREE.Float32BufferAttribute(linePositions, 3));
}

updateParticleLines();
const lines = new THREE.LineSegments(lineGeometry, lineMaterial);
scene.add(lines);

// Mouse tracking for interactive rotation
let mouseX = 0;
let mouseY = 0;
let targetRotationX = 0;
let targetRotationY = 0;

// Track mouse movement
document.addEventListener('mousemove', (event) => {
    // Normalize mouse position to -1 to 1
    mouseX = (event.clientX / window.innerWidth) * 2 - 1;
    mouseY = (event.clientY / window.innerHeight) * 2 - 1;
});

// Mobile accelerometer support for gyroscope-based interaction
let isUsingAccelerometer = false;

// Check if device supports orientation
if (window.DeviceOrientationEvent) {
    // Request permission for iOS 13+
    if (typeof DeviceOrientationEvent.requestPermission === 'function') {
        // iOS requires user interaction first - we'll auto-request on first touch
        document.addEventListener('touchstart', requestOrientationPermission, { once: true });
    } else {
        // Non-iOS devices
        enableAccelerometer();
    }
}

function requestOrientationPermission() {
    DeviceOrientationEvent.requestPermission()
        .then(permissionState => {
            if (permissionState === 'granted') {
                enableAccelerometer();
            }
        })
        .catch(console.error);
}

function enableAccelerometer() {
    window.addEventListener('deviceorientation', handleOrientation);
    isUsingAccelerometer = true;
}

function handleOrientation(event) {
    // Get device orientation (beta = front-to-back tilt, gamma = left-to-right tilt)
    const beta = event.beta;   // -180 to 180 degrees (front-back tilt)
    const gamma = event.gamma;  // -90 to 90 degrees (left-right tilt)

    if (beta !== null && gamma !== null) {
        // Convert to normalized values (-1 to 1) for consistency with mouse movement
        // Gamma (left-right): -90 to 90 -> map to -1 to 1
        mouseX = Math.max(-1, Math.min(1, gamma / 45)); // Divide by 45 for sensitivity

        // Beta (front-back): Use range around portrait position (around 90 degrees in portrait)
        // Adjust for portrait mode: 90 is neutral, tilt forward/back from there
        const adjustedBeta = beta - 90; // Center around 0
        mouseY = Math.max(-1, Math.min(1, adjustedBeta / 45)); // Divide by 45 for sensitivity
    }
}

// Load GLB model
let model;
const loader = new THREE.GLTFLoader();

loader.load(
    'SunglassesKhronos.glb',
    function (gltf) {
        model = gltf.scene;

        // Center and scale the model
        const box = new THREE.Box3().setFromObject(model);
        const center = box.getCenter(new THREE.Vector3());
        const size = box.getSize(new THREE.Vector3());

        // Center the model
        model.position.sub(center);

        // Scale to fit screen nicely - smaller on mobile
        const maxDim = Math.max(size.x, size.y, size.z);
        const isMobile = window.innerWidth <= 768;
        const baseScale = isMobile ? 18 : 28.08; // Smaller scale for mobile
        const scale = baseScale / maxDim;
        model.scale.setScalar(scale);

        // Position sunglasses - adjust for better viewing angle
        model.position.y = -1;
        model.rotation.y = 0.3; // Slight angle to show off the design

        scene.add(model);

        // Apply environment map if ready
        if (envReady) {
            updateModelMaterials();
        }
    },
    function (xhr) {
        console.log((xhr.loaded / xhr.total * 100) + '% loaded');
    },
    function (error) {
        console.error('Error loading sunglasses model:', error);
    }
);

// Handle window resize
window.addEventListener('resize', () => {
    camera.aspect = window.innerWidth / window.innerHeight;
    camera.updateProjectionMatrix();
    renderer.setSize(window.innerWidth, window.innerHeight);
});

// Animation loop
function animate() {
    requestAnimationFrame(animate);

    if (model) {
        // Calculate target rotation based on mouse position
        targetRotationY = mouseX * 0.3; // Horizontal rotation (max ±0.3 radians ≈ ±17 degrees)
        targetRotationX = mouseY * 0.2; // Vertical rotation (max ±0.2 radians ≈ ±11 degrees)

        // Smooth interpolation for natural movement
        model.rotation.y += (targetRotationY - model.rotation.y) * 0.05;
        model.rotation.x += (targetRotationX - model.rotation.x) * 0.05;
    }

    // Subtle particle network movement based on mouse (slower, more subtle)
    particles.rotation.y += (mouseX * 0.1 - particles.rotation.y) * 0.02;
    particles.rotation.x += (mouseY * 0.05 - particles.rotation.x) * 0.02;
    lines.rotation.y = particles.rotation.y;
    lines.rotation.x = particles.rotation.x;

    // Animate particles moving slowly towards the camera
    const particlePositionsArray = particleGeometry.attributes.position.array;
    let needsLineUpdate = false;

    for (let i = 0; i < particleCount; i++) {
        const i3 = i * 3;

        // Move particle forward (towards camera) slowly
        particlePositionsArray[i3 + 2] += 0.05; // Slow forward movement
        particlePositions[i].z += 0.05;

        // Reset particle to back if it gets too close
        if (particlePositionsArray[i3 + 2] > 15) {
            particlePositionsArray[i3 + 2] = -45; // Reset to far back
            particlePositions[i].z = -45;
            needsLineUpdate = true;
        }
    }

    particleGeometry.attributes.position.needsUpdate = true;

    // Update connecting lines periodically
    if (needsLineUpdate) {
        updateParticleLines();
    }

    // Update mouse spotlight position
    mouseLight.position.x = mouseX * 8;
    mouseLight.position.y = -mouseY * 6 + 2;
    mouseLight.target.position.set(0, 0, 0);
    mouseLight.target.updateMatrixWorld();

    renderer.render(scene, camera);
}

// Start animation
animate();


// ===== PAINT REVEAL EFFECT =====
const paintCanvas = document.getElementById('paint-canvas');
const paintCtx = paintCanvas.getContext('2d');

// Set canvas size
function resizePaintCanvas() {
    paintCanvas.width = window.innerWidth;
    paintCanvas.height = window.innerHeight;
    drawInitialText();
}
resizePaintCanvas();
window.addEventListener('resize', resizePaintCanvas);

// Draw the hidden text initially
function drawInitialText() {
    // Keep canvas clear - helmet always visible
    paintCtx.clearRect(0, 0, paintCanvas.width, paintCanvas.height);
}

// Raycaster for detecting mouse over helmet
const raycaster = new THREE.Raycaster();
const mouseVector = new THREE.Vector2();
let isOverHelmet = false;
let lastPaintPos = null;

// Track current mouse position
let currentMousePos = { x: 0, y: 0 };

// Track mouse movement for raycasting
document.addEventListener('mousemove', (event) => {
    currentMousePos = { x: event.clientX, y: event.clientY };

    // Update raycaster
    mouseVector.x = (event.clientX / window.innerWidth) * 2 - 1;
    mouseVector.y = -(event.clientY / window.innerHeight) * 2 + 1;

    raycaster.setFromCamera(mouseVector, camera);

    if (model) {
        const intersects = raycaster.intersectObject(model, true);
        isOverHelmet = intersects.length > 0;

        // Update cursor
        if (isOverHelmet) {
            document.body.classList.add('painting');
        } else {
            document.body.classList.remove('painting');
        }
    }
});

// Track lagging mouse position for delay effect
let laggedMousePos = { x: 0, y: 0 };
const LAG_FACTOR = 0.02; // Lower = more lag/delay (increased delay)

// Continuous render loop for spotlight effect (disabled - text reveal removed)
function renderSpotlight() {
    // Clear canvas and keep it empty (text reveal effect removed)
    paintCtx.clearRect(0, 0, paintCanvas.width, paintCanvas.height);
    requestAnimationFrame(renderSpotlight);
}

renderSpotlight();


// ===== PARALLAX SCROLL EFFECT =====
const canvasContainer = document.getElementById('canvas-container');
const paintCanvasElement = document.getElementById('paint-canvas');

window.addEventListener('scroll', () => {
    const scrollY = window.scrollY;

    // Different speeds for depth effect
    const helmetOffset = scrollY * 0.5; // Helmet moves slower (appears farther)
    const textOffset = scrollY * 0.8; // Text moves faster (appears closer)

    canvasContainer.style.transform = `translateY(-${helmetOffset}px)`;
    paintCanvasElement.style.transform = `translateY(-${textOffset}px)`;
});


// ===== NAVIGATION =====
const navbar = document.querySelector('.navbar');
const navBurger = document.getElementById('navBurger');
const navLinks = document.querySelector('.nav-links');

// Navbar scroll effect
window.addEventListener('scroll', () => {
    if (window.scrollY > 100) {
        navbar.classList.add('scrolled');
    } else {
        navbar.classList.remove('scrolled');
    }

});

// Mobile burger menu
navBurger?.addEventListener('click', (e) => {
    e.stopPropagation();
    navLinks.classList.toggle('active');
    navBurger.classList.toggle('active');
});

// Close menu when clicking nav links
document.querySelectorAll('.nav-links a').forEach(link => {
    link.addEventListener('click', () => {
        navLinks.classList.remove('active');
        navBurger.classList.remove('active');
    });
});

// Close menu when clicking outside
document.addEventListener('click', (e) => {
    if (!navLinks.contains(e.target) && !navBurger.contains(e.target)) {
        navLinks.classList.remove('active');
        navBurger.classList.remove('active');
    }
});

// Logo click to scroll to top
const navLogo = document.querySelector('.nav-logo');
navLogo?.addEventListener('click', (e) => {
    e.preventDefault();
    window.scrollTo({
        top: 0,
        behavior: 'smooth'
    });
});

// Smooth scroll for navigation links
document.querySelectorAll('a[href^="#"]').forEach(anchor => {
    anchor.addEventListener('click', function (e) {
        // Skip if this is the logo (already handled above)
        if (this.classList.contains('nav-logo')) return;

        e.preventDefault();
        const target = document.querySelector(this.getAttribute('href'));
        if (target) {
            target.scrollIntoView({
                behavior: 'smooth',
                block: 'start'
            });
            navLinks.classList.remove('active');
        }
    });
});

// ===== GT7 STATS AUTO-LOADER =====
const checkerResults = document.getElementById('checkerResults');

// Your GT7 credentials (from lookupPSN API)
const MY_USER_ID = '85596fe8-f2f8-45c1-9474-f3357e8d9446';
const MY_PSN = 'SparksTheory';

// Load stats automatically on page load
async function loadMyGT7Stats() {
    try {
        // Use CORS proxy to fetch your full stats history
        const apiUrl = `https://gtstats.live/api/getDriverStatsHistory?user_id=${MY_USER_ID}&psn=${encodeURIComponent(MY_PSN)}`;
        const proxyUrl = `https://api.allorigins.win/get?url=${encodeURIComponent(apiUrl)}`;

        const response = await fetch(proxyUrl);
        const proxyData = await response.json();

        console.log('GT7 Stats Response:', proxyData);

        if (!response.ok) {
            throw new Error(`API returned ${response.status}`);
        }

        const data = JSON.parse(proxyData.contents);
        displayDriverStats(MY_PSN, data);

    } catch (error) {
        console.error('Error loading GT7 stats:', error);

        // Fallback to manual stats display
        checkerResults.innerHTML = `
            <div style="max-width: 600px; margin: 0 auto;">
                <div style="display: grid; grid-template-columns: repeat(2, 1fr); gap: 1.5rem; margin-bottom: 2rem;">
                    <div style="background: linear-gradient(135deg, rgba(0,255,136,0.1) 0%, rgba(0,255,136,0.05) 100%); border: 2px solid rgba(0,255,136,0.3); border-radius: 12px; padding: 2rem; text-align: center; position: relative; overflow: hidden;">
                        <div style="position: absolute; top: 0; left: 0; right: 0; height: 4px; background: linear-gradient(90deg, var(--color-primary), var(--color-secondary));"></div>
                        <div style="font-size: 0.75rem; text-transform: uppercase; letter-spacing: 2px; color: var(--color-text-muted); margin-bottom: 0.5rem;">Driver Rating</div>
                        <div style="font-size: 3rem; font-weight: 900; font-family: var(--font-display); color: var(--color-primary); line-height: 1; margin-bottom: 0.25rem;">A+</div>
                        <div style="font-size: 1.25rem; font-weight: 600; color: rgba(255,255,255,0.8);">55,316 DR</div>
                    </div>
                    <div style="background: linear-gradient(135deg, rgba(14,165,233,0.1) 0%, rgba(14,165,233,0.05) 100%); border: 2px solid rgba(14,165,233,0.3); border-radius: 12px; padding: 2rem; text-align: center; position: relative; overflow: hidden;">
                        <div style="position: absolute; top: 0; left: 0; right: 0; height: 4px; background: linear-gradient(90deg, var(--color-secondary), var(--color-primary));"></div>
                        <div style="font-size: 0.75rem; text-transform: uppercase; letter-spacing: 2px; color: var(--color-text-muted); margin-bottom: 0.5rem;">Sportsmanship</div>
                        <div style="font-size: 3rem; font-weight: 900; font-family: var(--font-display); color: var(--color-secondary); line-height: 1; margin-bottom: 0.25rem;">S</div>
                        <div style="font-size: 1.25rem; font-weight: 600; color: rgba(255,255,255,0.8);">99 SR</div>
                    </div>
                </div>
                <div style="background: rgba(255,255,255,0.03); border: 1px solid rgba(255,255,255,0.1); border-radius: 12px; padding: 1.5rem;">
                    <div style="display: grid; grid-template-columns: repeat(2, 1fr); gap: 1.5rem;">
                        <div style="text-align: center;">
                            <div style="font-size: 2rem; font-weight: 700; color: var(--color-primary);">SparksTheory</div>
                            <div style="font-size: 0.875rem; color: var(--color-text-muted); text-transform: uppercase; letter-spacing: 1px;">PSN ID</div>
                        </div>
                        <div style="text-align: center;">
                            <div style="font-size: 2rem; font-weight: 700; color: var(--color-text);">Active</div>
                            <div style="font-size: 0.875rem; color: var(--color-text-muted); text-transform: uppercase; letter-spacing: 1px;">GT7 Sport Mode</div>
                        </div>
                    </div>
                </div>
            </div>
        `;
    }
}

// Load stats when page is ready
document.addEventListener('DOMContentLoaded', loadMyGT7Stats);

function displayDriverStats(psnId, data) {
    // Parse the API response and display relevant stats
    console.log('API Response:', data);

    // Check if we have valid data
    if (!data || (Array.isArray(data) && data.length === 0)) {
        checkerResults.innerHTML = `
            <div style="text-align: left;">
                <p style="color: var(--color-accent);">No stats found for "${psnId}"</p>
                <p style="color: var(--color-text-muted); font-size: 0.9rem; margin-top: 1rem;">
                    Make sure the PSN ID is correct and the player has participated in GT7 Sport mode.
                </p>
            </div>
        `;
        return;
    }

    // Helper function to convert SR number to letter grade (API uses 0-6 scale)
    function getSRGrade(sr) {
        // GT7 API SR scale: 6=S, 5=A, 4=B, 3=C, 2=D, 1=E, 0=E
        const grades = ['E', 'E', 'D', 'C', 'B', 'A', 'S'];
        return grades[sr] || 'E';
    }

    // Get the most recent stats (data is an object with numeric keys)
    const latestStats = data["0"] || data[0] || data;

    // Debug: Log all available fields
    console.log('All stats fields:', latestStats);

    // Extract GT7 stat fields from API using correct field names
    const drPoints = latestStats.dr || 0;
    const driverRating = latestStats.rank || 'E';  // API provides the letter grade directly!
    const srValue = latestStats.sr || 0;
    const sportsmanship = getSRGrade(srValue);
    const totalRaces = latestStats.raceCount || 0;
    const wins = latestStats.winCount || 0;
    const poles = latestStats.polePositionCount || 0;
    const fastestLaps = latestStats.fastestLapCount || 0;

    console.log('DR Points:', drPoints, 'DR Grade:', driverRating, 'SR Value:', srValue, 'SR Grade:', sportsmanship);

    checkerResults.innerHTML = `
        <div style="max-width: 700px; margin: 0 auto;">
            <!-- DR & SR Cards -->
            <div style="display: grid; grid-template-columns: repeat(2, 1fr); gap: 1.5rem; margin-bottom: 1.5rem;">
                <div style="background: linear-gradient(135deg, rgba(0,255,136,0.15) 0%, rgba(0,255,136,0.05) 100%); border: 2px solid rgba(0,255,136,0.4); border-radius: 16px; padding: 2rem; text-align: center; position: relative; overflow: hidden; box-shadow: 0 8px 32px rgba(0,255,136,0.15);">
                    <div style="position: absolute; top: 0; left: 0; right: 0; height: 4px; background: linear-gradient(90deg, var(--color-primary), var(--color-secondary));"></div>
                    <div style="font-size: 0.7rem; text-transform: uppercase; letter-spacing: 3px; color: var(--color-text-muted); margin-bottom: 0.5rem; font-weight: 600;">Driver Rating</div>
                    <div style="font-size: 3.5rem; font-weight: 900; font-family: var(--font-display); color: var(--color-primary); line-height: 1; margin-bottom: 0.5rem; text-shadow: 0 0 20px rgba(0,255,136,0.3);">${driverRating}</div>
                    <div style="font-size: 1.1rem; font-weight: 700; color: rgba(255,255,255,0.9);">${drPoints ? drPoints.toLocaleString() : '0'} <span style="color: var(--color-text-muted); font-weight: 500;">points</span></div>
                </div>
                <div style="background: linear-gradient(135deg, rgba(14,165,233,0.15) 0%, rgba(14,165,233,0.05) 100%); border: 2px solid rgba(14,165,233,0.4); border-radius: 16px; padding: 2rem; text-align: center; position: relative; overflow: hidden; box-shadow: 0 8px 32px rgba(14,165,233,0.15);">
                    <div style="position: absolute; top: 0; left: 0; right: 0; height: 4px; background: linear-gradient(90deg, var(--color-secondary), var(--color-primary));"></div>
                    <div style="font-size: 0.7rem; text-transform: uppercase; letter-spacing: 3px; color: var(--color-text-muted); margin-bottom: 0.5rem; font-weight: 600;">Sportsmanship</div>
                    <div style="font-size: 3.5rem; font-weight: 900; font-family: var(--font-display); color: var(--color-secondary); line-height: 1; margin-bottom: 0.5rem; text-shadow: 0 0 20px rgba(14,165,233,0.3);">${sportsmanship}</div>
                    <div style="font-size: 1.1rem; font-weight: 700; color: rgba(255,255,255,0.9);">${srValue ? srValue : '0'} <span style="color: var(--color-text-muted); font-weight: 500;">rating</span></div>
                </div>
            </div>

            <!-- Racing Stats Grid -->
            <div style="display: grid; grid-template-columns: repeat(2, 1fr); gap: 1rem; margin-bottom: 1.5rem;">
                <div style="background: rgba(255,255,255,0.05); border: 1px solid rgba(0,255,136,0.2); border-radius: 12px; padding: 1.5rem; text-align: center; transition: all 0.3s ease;">
                    <div style="font-size: 2.5rem; font-weight: 800; color: var(--color-primary); font-family: var(--font-display); margin-bottom: 0.25rem;">${totalRaces || 0}</div>
                    <div style="font-size: 0.75rem; color: var(--color-text-muted); text-transform: uppercase; letter-spacing: 2px; font-weight: 600;">Races</div>
                </div>
                <div style="background: rgba(255,255,255,0.05); border: 1px solid rgba(0,255,136,0.2); border-radius: 12px; padding: 1.5rem; text-align: center; transition: all 0.3s ease;">
                    <div style="font-size: 2.5rem; font-weight: 800; color: var(--color-primary); font-family: var(--font-display); margin-bottom: 0.25rem;">${wins || 0}</div>
                    <div style="font-size: 0.75rem; color: var(--color-text-muted); text-transform: uppercase; letter-spacing: 2px; font-weight: 600;">Wins</div>
                </div>
                <div style="background: rgba(255,255,255,0.05); border: 1px solid rgba(14,165,233,0.2); border-radius: 12px; padding: 1.5rem; text-align: center; transition: all 0.3s ease;">
                    <div style="font-size: 2.5rem; font-weight: 800; color: var(--color-secondary); font-family: var(--font-display); margin-bottom: 0.25rem;">${poles || 0}</div>
                    <div style="font-size: 0.75rem; color: var(--color-text-muted); text-transform: uppercase; letter-spacing: 2px; font-weight: 600;">Pole Positions</div>
                </div>
                <div style="background: rgba(255,255,255,0.05); border: 1px solid rgba(14,165,233,0.2); border-radius: 12px; padding: 1.5rem; text-align: center; transition: all 0.3s ease;">
                    <div style="font-size: 2.5rem; font-weight: 800; color: var(--color-secondary); font-family: var(--font-display); margin-bottom: 0.25rem;">${fastestLaps || 0}</div>
                    <div style="font-size: 0.75rem; color: var(--color-text-muted); text-transform: uppercase; letter-spacing: 2px; font-weight: 600;">Fastest Laps</div>
                </div>
            </div>

            <!-- PSN ID Badge -->
            <div style="background: linear-gradient(135deg, rgba(255,255,255,0.1) 0%, rgba(255,255,255,0.03) 100%); border: 1px solid rgba(255,255,255,0.15); border-radius: 12px; padding: 1.25rem; text-align: center;">
                <div style="font-size: 1.75rem; font-weight: 800; color: var(--color-primary); font-family: var(--font-display); letter-spacing: 1px;">${psnId}</div>
                <div style="font-size: 0.7rem; color: var(--color-text-muted); text-transform: uppercase; letter-spacing: 2px; margin-top: 0.25rem; font-weight: 600;">PSN ID • GT7 Sport Mode</div>
            </div>
        </div>
    `;
}

// ===== CONTACT FORM =====
const contactForm = document.getElementById('contactForm');

contactForm?.addEventListener('submit', (e) => {
    e.preventDefault();

    const formData = new FormData(contactForm);
    const submitBtn = contactForm.querySelector('button[type="submit"]');
    const originalText = submitBtn.textContent;

    submitBtn.textContent = 'Sending...';
    submitBtn.disabled = true;

    // Submit to Netlify Forms
    fetch('/', {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body: new URLSearchParams(formData).toString()
    })
    .then(() => {
        submitBtn.textContent = 'Message Sent!';
        submitBtn.style.background = 'var(--color-secondary)';
        contactForm.reset();

        setTimeout(() => {
            submitBtn.textContent = originalText;
            submitBtn.disabled = false;
            submitBtn.style.background = '';
        }, 3000);
    })
    .catch((error) => {
        console.error('Form submission error:', error);
        submitBtn.textContent = 'Error - Try Again';
        submitBtn.style.background = '#ef4444';

        setTimeout(() => {
            submitBtn.textContent = originalText;
            submitBtn.disabled = false;
            submitBtn.style.background = '';
        }, 3000);
    });
});

// ===== SCROLL ANIMATIONS =====
const observerOptions = {
    threshold: 0.1,
    rootMargin: '0px 0px -100px 0px'
};

const observer = new IntersectionObserver((entries) => {
    entries.forEach(entry => {
        if (entry.isIntersecting) {
            entry.target.style.opacity = '1';
            entry.target.style.transform = 'translateY(0)';
        }
    });
}, observerOptions);

document.querySelectorAll('.section').forEach(section => {
    section.style.opacity = '0';
    section.style.transform = 'translateY(30px)';
    section.style.transition = 'opacity 0.8s ease, transform 0.8s ease';
    observer.observe(section);
});

// ===== YOUR GT7 STATS LOOKUP =====
const lookupStatsBtn = document.getElementById('lookupStatsBtn');
const psnIdInput = document.getElementById('psnIdInput');
const gtProfileUrl = document.getElementById('gtProfileUrl');
const userStatsResults = document.getElementById('userStatsResults');

lookupStatsBtn?.addEventListener('click', async () => {
    const psnId = psnIdInput.value.trim();

    if (!psnId) {
        alert('Please enter your PSN ID');
        return;
    }

    lookupStatsBtn.textContent = 'Loading...';
    lookupStatsBtn.disabled = true;

    try {
        // Use our Netlify proxy to fetch gtstats.live data (bypasses CORS)
        const response = await fetch(`/.netlify/functions/gtstats-proxy?psnId=${encodeURIComponent(psnId)}`);
        const data = await response.json();

        console.log('Proxy API response:', data);

        if (!data.success) {
            throw new Error(data.error || 'Player not found');
        }

        const statsData = data.player;

        console.log('Player stats:', statsData);

        displayUserStats(psnId, statsData.id, statsData);
    } catch (error) {
        console.error('Error fetching stats:', error);
        userStatsResults.innerHTML = `
            <div style="background: rgba(239,68,68,0.1); border: 2px solid rgba(239,68,68,0.3); border-radius: 12px; padding: 2rem; text-align: center;">
                <p style="color: #fca5a5; font-size: 1.2rem; margin-bottom: 1rem;">Error Loading Stats</p>
                <p style="color: var(--color-text-muted);">Player not found in our database. If you get an error, DM me in discord and I will add you to the database.</p>
            </div>
        `;
        userStatsResults.style.display = 'block';
    } finally {
        lookupStatsBtn.textContent = 'View My Stats';
        lookupStatsBtn.disabled = false;
    }
});

function displayUserStats(psnId, userGuid, data) {
    if (!data || (Array.isArray(data) && data.length === 0)) {
        userStatsResults.innerHTML = `
            <div style="background: rgba(239,68,68,0.1); border: 2px solid rgba(239,68,68,0.3); border-radius: 12px; padding: 2rem; text-align: center;">
                <p style="color: #fca5a5;">No stats found for this profile.</p>
            </div>
        `;
        userStatsResults.style.display = 'block';
        return;
    }

    function getSRGrade(sr) {
        const grades = ['E', 'E', 'D', 'C', 'B', 'A', 'S'];
        return grades[sr] || 'E';
    }

    const latestStats = data["0"] || data[0] || data;
    const drPoints = latestStats.dr || 0;
    const driverRating = latestStats.rank || 'E';
    const srValue = latestStats.sr || 0;
    const sportsmanship = getSRGrade(srValue);
    const totalRaces = latestStats.raceCount || 0;
    const wins = latestStats.winCount || 0;
    const poles = latestStats.polePositionCount || 0;
    const fastestLaps = latestStats.fastestLapCount || 0;

    userStatsResults.innerHTML = `
        <div style="animation: fadeIn 0.5s ease-in;">
            <!-- DR & SR Cards -->
            <div style="display: grid; grid-template-columns: repeat(2, 1fr); gap: 1.5rem; margin-bottom: 1.5rem;">
                <div style="background: linear-gradient(135deg, rgba(0,255,136,0.15) 0%, rgba(0,255,136,0.05) 100%); border: 2px solid rgba(0,255,136,0.4); border-radius: 16px; padding: 2rem; text-align: center; position: relative; overflow: hidden;">
                    <div style="position: absolute; top: 0; left: 0; right: 0; height: 4px; background: linear-gradient(90deg, var(--color-primary), var(--color-secondary));"></div>
                    <div style="font-size: 0.7rem; text-transform: uppercase; letter-spacing: 3px; color: var(--color-text-muted); margin-bottom: 0.5rem; font-weight: 600;">Driver Rating</div>
                    <div style="font-size: 3.5rem; font-weight: 900; font-family: var(--font-display); color: var(--color-primary); line-height: 1; margin-bottom: 0.5rem;">${driverRating}</div>
                    <div style="font-size: 1.1rem; font-weight: 700; color: rgba(255,255,255,0.9);">${drPoints.toLocaleString()} <span style="color: var(--color-text-muted); font-weight: 500;">points</span></div>
                </div>
                <div style="background: linear-gradient(135deg, rgba(14,165,233,0.15) 0%, rgba(14,165,233,0.05) 100%); border: 2px solid rgba(14,165,233,0.4); border-radius: 16px; padding: 2rem; text-align: center; position: relative; overflow: hidden;">
                    <div style="position: absolute; top: 0; left: 0; right: 0; height: 4px; background: linear-gradient(90deg, var(--color-secondary), var(--color-primary));"></div>
                    <div style="font-size: 0.7rem; text-transform: uppercase; letter-spacing: 3px; color: var(--color-text-muted); margin-bottom: 0.5rem; font-weight: 600;">Sportsmanship</div>
                    <div style="font-size: 3.5rem; font-weight: 900; font-family: var(--font-display); color: var(--color-secondary); line-height: 1; margin-bottom: 0.5rem;">${sportsmanship}</div>
                    <div style="font-size: 1.1rem; font-weight: 700; color: rgba(255,255,255,0.9);">${srValue} <span style="color: var(--color-text-muted); font-weight: 500;">rating</span></div>
                </div>
            </div>

            <!-- Racing Stats -->
            <div style="display: grid; grid-template-columns: repeat(4, 1fr); gap: 1rem; margin-bottom: 1.5rem;">
                <div style="background: rgba(255,255,255,0.05); border: 1px solid rgba(255,255,255,0.1); border-radius: 12px; padding: 1.25rem; text-align: center;">
                    <div style="font-size: 2rem; font-weight: 800; color: var(--color-primary);">${totalRaces}</div>
                    <div style="font-size: 0.7rem; color: var(--color-text-muted); text-transform: uppercase; letter-spacing: 1px;">Races</div>
                </div>
                <div style="background: rgba(255,255,255,0.05); border: 1px solid rgba(255,255,255,0.1); border-radius: 12px; padding: 1.25rem; text-align: center;">
                    <div style="font-size: 2rem; font-weight: 800; color: var(--color-primary);">${wins}</div>
                    <div style="font-size: 0.7rem; color: var(--color-text-muted); text-transform: uppercase; letter-spacing: 1px;">Wins</div>
                </div>
                <div style="background: rgba(255,255,255,0.05); border: 1px solid rgba(255,255,255,0.1); border-radius: 12px; padding: 1.25rem; text-align: center;">
                    <div style="font-size: 2rem; font-weight: 800; color: var(--color-primary);">${poles}</div>
                    <div style="font-size: 0.7rem; color: var(--color-text-muted); text-transform: uppercase; letter-spacing: 1px;">Poles</div>
                </div>
                <div style="background: rgba(255,255,255,0.05); border: 1px solid rgba(255,255,255,0.1); border-radius: 12px; padding: 1.25rem; text-align: center;">
                    <div style="font-size: 2rem; font-weight: 800; color: var(--color-primary);">${fastestLaps}</div>
                    <div style="font-size: 0.7rem; color: var(--color-text-muted); text-transform: uppercase; letter-spacing: 1px;">Fast Laps</div>
                </div>
            </div>

            <!-- PSN Badge -->
            <div style="background: linear-gradient(135deg, rgba(255,255,255,0.1) 0%, rgba(255,255,255,0.03) 100%); border: 1px solid rgba(255,255,255,0.15); border-radius: 12px; padding: 1.25rem; text-align: center; margin-bottom: 1.5rem;">
                <div style="font-size: 1.75rem; font-weight: 800; color: var(--color-primary); font-family: var(--font-display); letter-spacing: 1px;">${psnId}</div>
                <div style="font-size: 0.7rem; color: var(--color-text-muted); text-transform: uppercase; letter-spacing: 2px; margin-top: 0.25rem; font-weight: 600;">PSN ID • GT7 Sport Mode</div>
            </div>

            <!-- Download Widget Button -->
            <button
                onclick="downloadOBSWidget('${psnId}', '${userGuid}')"
                class="btn btn-primary"
                style="width: 100%; font-size: 1.2rem; padding: 1.25rem; background: linear-gradient(135deg, var(--color-primary), var(--color-secondary)); border: none; box-shadow: 0 8px 32px rgba(0,255,136,0.3); margin-bottom: 1rem;"
            >
                📥 Download Custom OBS Widget
            </button>

            <!-- Share Stats Card Button -->
            <button
                onclick="generateShareableCard('${psnId}', ${drPoints}, '${driverRating}', ${srValue}, '${sportsmanship}', ${totalRaces}, ${wins}, ${poles}, ${fastestLaps})"
                class="btn btn-secondary"
                style="width: 100%; font-size: 1.2rem; padding: 1.25rem; margin-bottom: 1.5rem; background: linear-gradient(135deg, rgba(138,43,226,0.8), rgba(75,0,130,0.8)); border: none; box-shadow: 0 4px 16px rgba(138,43,226,0.3);"
            >
                📸 Download Shareable Stats Card
            </button>

            <!-- Country Selector -->
            <div style="margin-bottom: 1rem;">
                <label style="display: block; color: var(--color-text-muted); font-size: 0.85rem; margin-bottom: 0.5rem; text-transform: uppercase; letter-spacing: 1px;">
                    Select Your Country
                </label>
                <select id="countrySelector" style="width: 100%; padding: 0.75rem; background: rgba(255,255,255,0.05); border: 2px solid rgba(255,255,255,0.1); border-radius: 8px; color: var(--text-color); font-size: 1rem;">
                    <option value="">🌍 Select Country</option>
                    <option value="US">🇺🇸 United States</option>
                    <option value="GB">🇬🇧 United Kingdom</option>
                    <option value="JP">🇯🇵 Japan</option>
                    <option value="DE">🇩🇪 Germany</option>
                    <option value="FR">🇫🇷 France</option>
                    <option value="IT">🇮🇹 Italy</option>
                    <option value="ES">🇪🇸 Spain</option>
                    <option value="BR">🇧🇷 Brazil</option>
                    <option value="CA">🇨🇦 Canada</option>
                    <option value="AU">🇦🇺 Australia</option>
                    <option value="NL">🇳🇱 Netherlands</option>
                    <option value="BE">🇧🇪 Belgium</option>
                    <option value="CH">🇨🇭 Switzerland</option>
                    <option value="AT">🇦🇹 Austria</option>
                    <option value="SE">🇸🇪 Sweden</option>
                    <option value="NO">🇳🇴 Norway</option>
                    <option value="DK">🇩🇰 Denmark</option>
                    <option value="FI">🇫🇮 Finland</option>
                    <option value="PT">🇵🇹 Portugal</option>
                    <option value="PL">🇵🇱 Poland</option>
                    <option value="CZ">🇨🇿 Czech Republic</option>
                    <option value="MX">🇲🇽 Mexico</option>
                    <option value="AR">🇦🇷 Argentina</option>
                    <option value="CL">🇨🇱 Chile</option>
                    <option value="NZ">🇳🇿 New Zealand</option>
                    <option value="ZA">🇿🇦 South Africa</option>
                    <option value="KR">🇰🇷 South Korea</option>
                    <option value="CN">🇨🇳 China</option>
                    <option value="TW">🇹🇼 Taiwan</option>
                    <option value="HK">🇭🇰 Hong Kong</option>
                    <option value="SG">🇸🇬 Singapore</option>
                    <option value="TH">🇹🇭 Thailand</option>
                    <option value="MY">🇲🇾 Malaysia</option>
                    <option value="ID">🇮🇩 Indonesia</option>
                    <option value="PH">🇵🇭 Philippines</option>
                    <option value="IN">🇮🇳 India</option>
                    <option value="AE">🇦🇪 UAE</option>
                    <option value="SA">🇸🇦 Saudi Arabia</option>
                    <option value="TR">🇹🇷 Turkey</option>
                    <option value="RU">🇷🇺 Russia</option>
                    <option value="GR">🇬🇷 Greece</option>
                    <option value="IE">🇮🇪 Ireland</option>
                    <option value="HU">🇭🇺 Hungary</option>
                    <option value="RO">🇷🇴 Romania</option>
                </select>
            </div>

            <!-- Submit to Leaderboard Button -->
            <button
                onclick="submitToLeaderboard('${psnId}', '${userGuid}', ${drPoints}, '${driverRating}', ${srValue}, '${sportsmanship}', ${totalRaces}, ${wins}, ${poles}, ${fastestLaps})"
                class="btn btn-secondary"
                style="width: 100%; font-size: 1.2rem; padding: 1.25rem;"
                id="submitLeaderboardBtn"
            >
                🏆 Submit to Global Leaderboard
            </button>
            <p style="font-size: 0.85rem; color: var(--color-text-muted); margin-top: 1rem;">
                Share your stats with the community and compete on the global rankings
            </p>
        </div>
    `;

    userStatsResults.style.display = 'block';
}

// Function to display stats from scraper (rank letters only, no DR points)
function displayUserStatsFromScraper(psnId, userGuid, data) {
    if (!data) {
        userStatsResults.innerHTML = `
            <div style="background: rgba(239,68,68,0.1); border: 2px solid rgba(239,68,68,0.3); border-radius: 12px; padding: 2rem; text-align: center;">
                <p style="color: #fca5a5;">No stats found for this profile.</p>
            </div>
        `;
        userStatsResults.style.display = 'block';
        return;
    }

    const driverRating = data.rank || 'E';
    const sportsmanship = data.sr || 'E';
    const totalRaces = data.raceCount || 0;
    const wins = data.winCount || 0;
    const poles = data.polePositionCount || 0;
    const fastestLaps = data.fastestLapCount || 0;

    userStatsResults.innerHTML = `
        <div style="animation: fadeIn 0.5s ease-in;">
            <!-- DR & SR Cards -->
            <div style="display: grid; grid-template-columns: repeat(2, 1fr); gap: 1.5rem; margin-bottom: 1.5rem;">
                <div style="background: linear-gradient(135deg, rgba(0,255,136,0.15) 0%, rgba(0,255,136,0.05) 100%); border: 2px solid rgba(0,255,136,0.4); border-radius: 16px; padding: 2rem; text-align: center; position: relative; overflow: hidden;">
                    <div style="position: absolute; top: 0; left: 0; right: 0; height: 4px; background: linear-gradient(90deg, var(--color-primary), var(--color-secondary));"></div>
                    <div style="font-size: 0.7rem; text-transform: uppercase; letter-spacing: 3px; color: var(--color-text-muted); margin-bottom: 0.5rem; font-weight: 600;">Driver Rating</div>
                    <div style="font-size: 3.5rem; font-weight: 900; font-family: var(--font-display); color: var(--color-primary); line-height: 1; margin-bottom: 0.5rem;">${driverRating}</div>
                    <div style="font-size: 0.9rem; font-weight: 600; color: var(--color-text-muted); text-transform: uppercase; letter-spacing: 1px;">Rank</div>
                </div>
                <div style="background: linear-gradient(135deg, rgba(14,165,233,0.15) 0%, rgba(14,165,233,0.05) 100%); border: 2px solid rgba(14,165,233,0.4); border-radius: 16px; padding: 2rem; text-align: center; position: relative; overflow: hidden;">
                    <div style="position: absolute; top: 0; left: 0; right: 0; height: 4px; background: linear-gradient(90deg, var(--color-secondary), var(--color-primary));"></div>
                    <div style="font-size: 0.7rem; text-transform: uppercase; letter-spacing: 3px; color: var(--color-text-muted); margin-bottom: 0.5rem; font-weight: 600;">Sportsmanship</div>
                    <div style="font-size: 3.5rem; font-weight: 900; font-family: var(--font-display); color: var(--color-secondary); line-height: 1; margin-bottom: 0.5rem;">${sportsmanship}</div>
                    <div style="font-size: 0.9rem; font-weight: 600; color: var(--color-text-muted); text-transform: uppercase; letter-spacing: 1px;">Grade</div>
                </div>
            </div>

            <!-- Racing Stats -->
            <div style="display: grid; grid-template-columns: repeat(4, 1fr); gap: 1rem; margin-bottom: 1.5rem;">
                <div style="background: rgba(255,255,255,0.05); border: 1px solid rgba(255,255,255,0.1); border-radius: 12px; padding: 1.25rem; text-align: center;">
                    <div style="font-size: 2rem; font-weight: 800; color: var(--color-primary);">${totalRaces}</div>
                    <div style="font-size: 0.7rem; color: var(--color-text-muted); text-transform: uppercase; letter-spacing: 1px;">Races</div>
                </div>
                <div style="background: rgba(255,255,255,0.05); border: 1px solid rgba(255,255,255,0.1); border-radius: 12px; padding: 1.25rem; text-align: center;">
                    <div style="font-size: 2rem; font-weight: 800; color: var(--color-primary);">${wins}</div>
                    <div style="font-size: 0.7rem; color: var(--color-text-muted); text-transform: uppercase; letter-spacing: 1px;">Wins</div>
                </div>
                <div style="background: rgba(255,255,255,0.05); border: 1px solid rgba(255,255,255,0.1); border-radius: 12px; padding: 1.25rem; text-align: center;">
                    <div style="font-size: 2rem; font-weight: 800; color: var(--color-primary);">${poles}</div>
                    <div style="font-size: 0.7rem; color: var(--color-text-muted); text-transform: uppercase; letter-spacing: 1px;">Poles</div>
                </div>
                <div style="background: rgba(255,255,255,0.05); border: 1px solid rgba(255,255,255,0.1); border-radius: 12px; padding: 1.25rem; text-align: center;">
                    <div style="font-size: 2rem; font-weight: 800; color: var(--color-primary);">${fastestLaps}</div>
                    <div style="font-size: 0.7rem; color: var(--color-text-muted); text-transform: uppercase; letter-spacing: 1px;">Fast Laps</div>
                </div>
            </div>

            <!-- PSN Badge -->
            <div style="background: linear-gradient(135deg, rgba(255,255,255,0.1) 0%, rgba(255,255,255,0.03) 100%); border: 1px solid rgba(255,255,255,0.15); border-radius: 12px; padding: 1.25rem; text-align: center; margin-bottom: 1.5rem;">
                <div style="font-size: 1.75rem; font-weight: 800; color: var(--color-primary); font-family: var(--font-display); letter-spacing: 1px;">${psnId}</div>
                <div style="font-size: 0.7rem; color: var(--color-text-muted); text-transform: uppercase; letter-spacing: 2px; margin-top: 0.25rem; font-weight: 600;">PSN ID • GT7 Sport Mode</div>
            </div>

            <!-- Download Widget Button -->
            <button
                onclick="downloadOBSWidget('${psnId}', '${userGuid}')"
                class="btn btn-primary"
                style="width: 100%; font-size: 1.2rem; padding: 1.25rem; background: linear-gradient(135deg, var(--color-primary), var(--color-secondary)); border: none; box-shadow: 0 8px 32px rgba(0,255,136,0.3); margin-bottom: 1rem;"
            >
                📥 Download Custom OBS Widget
            </button>

            <!-- Share Stats Card Button -->
            <button
                onclick="generateShareableCard('${psnId}', 0, '${driverRating}', 0, '${sportsmanship}', ${totalRaces}, ${wins}, ${poles}, ${fastestLaps})"
                class="btn btn-secondary"
                style="width: 100%; font-size: 1.2rem; padding: 1.25rem; margin-bottom: 1.5rem; background: linear-gradient(135deg, rgba(138,43,226,0.8), rgba(75,0,130,0.8)); border: none; box-shadow: 0 4px 16px rgba(138,43,226,0.3);"
            >
                📸 Download Shareable Stats Card
            </button>

            <!-- Country Selector -->
            <div style="margin-bottom: 1rem;">
                <label style="display: block; color: var(--color-text-muted); font-size: 0.85rem; margin-bottom: 0.5rem; text-transform: uppercase; letter-spacing: 1px;">
                    Select Your Country
                </label>
                <select id="countrySelectorScraper" style="width: 100%; padding: 0.75rem; background: rgba(255,255,255,0.05); border: 2px solid rgba(255,255,255,0.1); border-radius: 8px; color: var(--text-color); font-size: 1rem;">
                    <option value="">🌍 Select Country</option>
                    <option value="US">🇺🇸 United States</option>
                    <option value="GB">🇬🇧 United Kingdom</option>
                    <option value="JP">🇯🇵 Japan</option>
                    <option value="DE">🇩🇪 Germany</option>
                    <option value="FR">🇫🇷 France</option>
                    <option value="IT">🇮🇹 Italy</option>
                    <option value="ES">🇪🇸 Spain</option>
                    <option value="BR">🇧🇷 Brazil</option>
                    <option value="CA">🇨🇦 Canada</option>
                    <option value="AU">🇦🇺 Australia</option>
                    <option value="NL">🇳🇱 Netherlands</option>
                    <option value="BE">🇧🇪 Belgium</option>
                    <option value="CH">🇨🇭 Switzerland</option>
                    <option value="AT">🇦🇹 Austria</option>
                    <option value="SE">🇸🇪 Sweden</option>
                    <option value="NO">🇳🇴 Norway</option>
                    <option value="DK">🇩🇰 Denmark</option>
                    <option value="FI">🇫🇮 Finland</option>
                    <option value="PT">🇵🇹 Portugal</option>
                    <option value="PL">🇵🇱 Poland</option>
                    <option value="CZ">🇨🇿 Czech Republic</option>
                    <option value="MX">🇲🇽 Mexico</option>
                    <option value="AR">🇦🇷 Argentina</option>
                    <option value="CL">🇨🇱 Chile</option>
                    <option value="NZ">🇳🇿 New Zealand</option>
                    <option value="ZA">🇿🇦 South Africa</option>
                    <option value="KR">🇰🇷 South Korea</option>
                    <option value="CN">🇨🇳 China</option>
                    <option value="TW">🇹🇼 Taiwan</option>
                    <option value="HK">🇭🇰 Hong Kong</option>
                    <option value="SG">🇸🇬 Singapore</option>
                    <option value="TH">🇹🇭 Thailand</option>
                    <option value="MY">🇲🇾 Malaysia</option>
                    <option value="ID">🇮🇩 Indonesia</option>
                    <option value="PH">🇵🇭 Philippines</option>
                    <option value="IN">🇮🇳 India</option>
                    <option value="AE">🇦🇪 UAE</option>
                    <option value="SA">🇸🇦 Saudi Arabia</option>
                    <option value="TR">🇹🇷 Turkey</option>
                    <option value="RU">🇷🇺 Russia</option>
                    <option value="GR">🇬🇷 Greece</option>
                    <option value="IE">🇮🇪 Ireland</option>
                    <option value="HU">🇭🇺 Hungary</option>
                    <option value="RO">🇷🇴 Romania</option>
                </select>
            </div>

            <!-- Submit to Leaderboard Button -->
            <button
                onclick="submitToLeaderboardFromScraper('${psnId}', '${userGuid}', '${driverRating}', '${sportsmanship}', ${totalRaces}, ${wins}, ${poles}, ${fastestLaps})"
                class="btn btn-secondary"
                style="width: 100%; font-size: 1.2rem; padding: 1.25rem;"
                id="submitLeaderboardBtn"
            >
                🏆 Submit to Global Leaderboard
            </button>
            <p style="font-size: 0.85rem; color: var(--color-text-muted); margin-top: 1rem;">
                Share your stats with the community and compete on the global rankings
            </p>
        </div>
    `;

    userStatsResults.style.display = 'block';
}

// Function to generate and download custom OBS widget
// OBS Widget Generator - Updated 2025-12-28 with fallback CORS proxies
async function downloadOBSWidget(psnId, userGuid) {
    // Fetch the template from the standalone widget file
    const response = await fetch('gt7-obs-widget.html');
    let widgetContent = await response.text();

    // Replace the CONFIG values with user's data
    widgetContent = widgetContent.replace(
        "PSN_ID: 'SparksTheory'",
        `PSN_ID: '${psnId}'`
    ).replace(
        "USER_ID: '85596fe8-f2f8-45c1-9474-f3357e8d9446'",
        `USER_ID: '${userGuid}'`
    );

    /*
    // OLD METHOD - Manual template (keeping for reference)
    const widgetContent = `<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>GT7 Stats OBS Widget - ${psnId}</title>
    <style>
        :root { --primary-color: #0ea5e9; --secondary-color: #38bdf8; --bg-color: rgba(10, 14, 18, 0.95); --border-color: rgba(96, 197, 255, 0.3); --text-color: #ffffff; --text-muted: #94a3b8; }
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body { font-family: 'Inter', 'Segoe UI', sans-serif; background: transparent; color: var(--text-color); overflow: hidden; }
        .widget-container { width: 850px; height: 60px; background: linear-gradient(180deg, rgba(96,197,255,0.08) 0%, rgba(14,165,233,0.08) 50%, rgba(96,197,255,0.08) 100%); border: 2px solid var(--border-color); border-radius: 8px; display: flex; align-items: center; padding: 0 1rem; gap: 0.8rem; box-shadow: 0 4px 20px rgba(0, 0, 0, 0.5); }
        .widget-container::before { content: ''; position: absolute; top: 0; left: 0; right: 0; height: 3px; background: linear-gradient(90deg, var(--primary-color), var(--secondary-color)); }
        .stat-item { display: flex; flex-direction: column; align-items: center; gap: 0.15rem; }
        .stat-label { font-size: 0.65rem; color: var(--text-muted); text-transform: uppercase; letter-spacing: 0.5px; font-weight: 600; }
        .stat-value { font-size: 1.1rem; font-weight: 700; color: var(--text-color); }
        .psn-name { min-width: 180px; font-size: 1.1rem; font-weight: 700; color: var(--primary-color); }
        .dr-stat { min-width: 120px; } .dr-stat .stat-value { color: var(--primary-color); font-size: 1.2rem; }
        .trend-graph { min-width: 100px; height: 40px; display: flex; align-items: center; justify-content: center; }
        .rank-stat .stat-value { color: var(--primary-color); font-size: 1.4rem; font-weight: 800; }
        .sr-stat .stat-value { color: var(--secondary-color); font-size: 1.3rem; font-weight: 800; }
        .percentage { color: var(--primary-color); } .percentage.alt { color: var(--secondary-color); }
        .loading { color: var(--text-muted); font-size: 0.9rem; }
    </style>
</head>
<body>
    <div class="widget-container">
        <div class="psn-name" id="psnName"><div class="stat-label">PSN ID</div><div class="loading">Loading...</div></div>
        <div class="stat-item dr-stat"><div class="stat-label">DR</div><div class="stat-value" id="drValue">-</div></div>
        <div class="trend-graph" id="trendGraph"><div class="stat-label">Trend</div></div>
        <div class="stat-item rank-stat"><div class="stat-label">Rank</div><div class="stat-value" id="rankValue">-</div></div>
        <div class="stat-item sr-stat"><div class="stat-label">SR</div><div class="stat-value" id="srValue">-</div></div>
        <div class="stat-item"><div class="stat-label">Races</div><div class="stat-value" id="racesValue">-</div></div>
        <div class="stat-item"><div class="stat-label">Win %</div><div class="stat-value percentage" id="winValue">-</div></div>
        <div class="stat-item"><div class="stat-label">Pole %</div><div class="stat-value percentage alt" id="poleValue">-</div></div>
        <div class="stat-item"><div class="stat-label">FL %</div><div class="stat-value percentage" id="flValue">-</div></div>
    </div>
    <script>
        const CONFIG = { PSN_ID: '${psnId}', USER_ID: '${userGuid}', COUNTRY_CODE: '', REFRESH_INTERVAL: 300000, USE_CORS_PROXY: true };
        let drHistoryCache = null;
        function createSparkline(historyData, width = 100, height = 40) { if (!historyData || typeof historyData !== 'object') return '<svg width="100" height="40"></svg>'; const dataPoints = Object.values(historyData).map(entry => entry.dr || 0).filter(dr => dr > 0).slice(-30).reverse(); if (dataPoints.length < 2) return '<svg width="100" height="40"></svg>'; const minDR = Math.min(...dataPoints); const maxDR = Math.max(...dataPoints); const range = maxDR - minDR || 1; const stepX = width / (dataPoints.length - 1); const points = dataPoints.map((dr, i) => { const x = i * stepX; const y = height - ((dr - minDR) / range * (height - 4)) - 2; return \\\`\\\${x},\\\${y}\\\`; }).join(' '); const trend = dataPoints[dataPoints.length - 1] - dataPoints[0]; const color = trend >= 0 ? '#00ff88' : '#ff4444'; return \\\`<svg width="\\\${width}" height="\\\${height}" style="display: block;"><polyline points="\\\${points}" fill="none" stroke="\\\${color}" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" opacity="0.8" /></svg>\\\`; }
        async function fetchDRHistory() { if (drHistoryCache) return drHistoryCache; const apiUrl = \\\`https://gtstats.live/api/getDriverStatsHistory?user_id=\\\${CONFIG.USER_ID}&psn=\\\${encodeURIComponent(CONFIG.PSN_ID)}\\\`; const proxies = [ { name: 'allorigins', url: \\\`https://api.allorigins.win/get?url=\\\${encodeURIComponent(apiUrl)}\\\`, parseResponse: (r) => JSON.parse(r.contents) }, { name: 'corsproxy.io', url: \\\`https://corsproxy.io/?\\\${encodeURIComponent(apiUrl)}\\\`, parseResponse: (r) => r }, { name: 'direct', url: apiUrl, parseResponse: (r) => r } ]; for (const proxy of proxies) { try { console.log(\\\`Trying \\\${proxy.name} for DR history:\\\`, proxy.url); const controller = new AbortController(); const timeoutId = setTimeout(() => controller.abort(), 10000); const response = await fetch(proxy.url, { signal: controller.signal }); clearTimeout(timeoutId); if (!response.ok) throw new Error(\\\`HTTP \\\${response.status}: \\\${response.statusText}\\\`); const responseData = await response.json(); const data = proxy.parseResponse(responseData); console.log(\\\`✓ \\\${proxy.name} succeeded for DR history\\\`); drHistoryCache = data; return data; } catch (error) { console.warn(\\\`✗ \\\${proxy.name} failed for DR history:\\\`, error.message); if (proxy === proxies[proxies.length - 1]) { console.error('All proxies failed for DR history'); return null; } } } }
        async function fetchGT7Stats() { const apiUrl = \\\`https://gtstats.live/api/getDriverRatingPSN?psn=\\\${encodeURIComponent(CONFIG.PSN_ID)}\\\`; const proxies = [ { name: 'allorigins', url: \\\`https://api.allorigins.win/get?url=\\\${encodeURIComponent(apiUrl)}\\\`, parseResponse: (r) => JSON.parse(r.contents) }, { name: 'corsproxy.io', url: \\\`https://corsproxy.io/?\\\${encodeURIComponent(apiUrl)}\\\`, parseResponse: (r) => r }, { name: 'direct', url: apiUrl, parseResponse: (r) => r } ]; for (const proxy of proxies) { try { console.log(\\\`Trying \\\${proxy.name}:\\\`, proxy.url); const controller = new AbortController(); const timeoutId = setTimeout(() => controller.abort(), 10000); const response = await fetch(proxy.url, { signal: controller.signal }); clearTimeout(timeoutId); if (!response.ok) throw new Error(\\\`HTTP \\\${response.status}: \\\${response.statusText}\\\`); const responseData = await response.json(); const data = proxy.parseResponse(responseData); console.log(\\\`✓ \\\${proxy.name} succeeded\\\`); return data; } catch (error) { console.warn(\\\`✗ \\\${proxy.name} failed:\\\`, error.message); if (proxy === proxies[proxies.length - 1]) throw new Error('All CORS proxies failed'); } } }
        function getSRGrade(sr) { const grades = ['E', 'E', 'D', 'C', 'B', 'A', 'S']; return grades[sr] || 'E'; }
        async function displayStats(data) { const drPoints = data.dr || 0; const driverRating = data.rank || 'E'; const srValue = data.sr || 0; const sportsmanship = getSRGrade(srValue); const totalRaces = data.raceCount || 0; const wins = data.winCount || 0; const poles = data.polePositionCount || 0; const fastestLaps = data.fastestLapCount || 0; const winPercentage = totalRaces > 0 ? ((wins / totalRaces) * 100).toFixed(1) : '0.0'; const polePercentage = totalRaces > 0 ? ((poles / totalRaces) * 100).toFixed(1) : '0.0'; const flPercentage = totalRaces > 0 ? ((fastestLaps / totalRaces) * 100).toFixed(1) : '0.0'; document.getElementById('psnName').innerHTML = \\\`<div class="stat-label">PSN ID</div><div class="stat-value">\\\${CONFIG.PSN_ID}</div>\\\`; document.getElementById('drValue').textContent = drPoints.toLocaleString(); document.getElementById('rankValue').textContent = driverRating; document.getElementById('srValue').textContent = sportsmanship; document.getElementById('racesValue').textContent = totalRaces.toLocaleString(); document.getElementById('winValue').textContent = winPercentage + '%'; document.getElementById('poleValue').textContent = polePercentage + '%'; document.getElementById('flValue').textContent = flPercentage + '%'; const historyData = await fetchDRHistory(); if (historyData) { document.getElementById('trendGraph').innerHTML = createSparkline(historyData, 100, 40); } }
        async function updateStats() { try { console.log('Fetching stats for:', CONFIG.PSN_ID); const data = await fetchGT7Stats(); console.log('Stats received:', data); await displayStats(data); } catch (error) { console.error('Failed to update stats:', error); document.getElementById('psnName').innerHTML = \\\`<div class="stat-label">ERROR</div><div class="loading" style="color: #ff4444;">Failed to load stats. Check console.</div>\\\`; } }
        console.log('Widget starting with config:', CONFIG); updateStats(); setInterval(updateStats, CONFIG.REFRESH_INTERVAL);
    </script>
</body>
</html>`;
    */

    // Create blob and download
    const blob = new Blob([widgetContent], { type: 'text/html' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = `gt7-widget-${psnId}.html`;
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    URL.revokeObjectURL(url);

    // Show success message
    alert(`✅ Widget downloaded!\n\nTo use in OBS:\n1. Add Browser Source\n2. Check "Local file"\n3. Select gt7-widget-${psnId}.html\n4. Set Width: 850, Height: 60\n5. Done!\n\nRefreshes every 5 minutes automatically.`);
}

// Generate shareable stats card
async function generateShareableCard(psnId, dr, rank, sr, srGrade, totalRaces, wins, poles, fastestLaps) {
    // Create canvas (1920x1080 for better quality)
    const canvas = document.createElement('canvas');
    canvas.width = 1920;
    canvas.height = 1080;
    const ctx = canvas.getContext('2d');

    // Background gradient
    const gradient = ctx.createLinearGradient(0, 0, 1920, 1080);
    gradient.addColorStop(0, '#0a0e12');
    gradient.addColorStop(0.5, '#151d28');
    gradient.addColorStop(1, '#0a0e12');
    ctx.fillStyle = gradient;
    ctx.fillRect(0, 0, 1920, 1080);

    // Add subtle grid pattern
    ctx.strokeStyle = 'rgba(0, 255, 136, 0.04)';
    ctx.lineWidth = 1;
    for (let i = 0; i < 1920; i += 60) {
        ctx.beginPath();
        ctx.moveTo(i, 0);
        ctx.lineTo(i, 1080);
        ctx.stroke();
    }
    for (let i = 0; i < 1080; i += 60) {
        ctx.beginPath();
        ctx.moveTo(0, i);
        ctx.lineTo(1920, i);
        ctx.stroke();
    }

    // Border with enhanced glow
    ctx.strokeStyle = '#00ff88';
    ctx.lineWidth = 8;
    ctx.shadowBlur = 40;
    ctx.shadowColor = '#00ff88';
    ctx.strokeRect(40, 40, 1840, 1000);
    ctx.shadowBlur = 0;

    // Title with shadow
    ctx.shadowBlur = 20;
    ctx.shadowColor = 'rgba(0, 255, 136, 0.5)';
    ctx.fillStyle = '#00ff88';
    ctx.font = 'bold 80px Orbitron';
    ctx.textAlign = 'center';
    ctx.fillText('GT7 SPORT MODE STATS', 960, 140);
    ctx.shadowBlur = 0;

    // PSN ID with enhanced background
    ctx.fillStyle = 'rgba(0, 255, 136, 0.12)';
    ctx.fillRect(410, 190, 1100, 110);
    ctx.strokeStyle = 'rgba(0, 255, 136, 0.3)';
    ctx.lineWidth = 2;
    ctx.strokeRect(410, 190, 1100, 110);
    ctx.fillStyle = '#ffffff';
    ctx.font = 'bold 76px Orbitron';
    ctx.fillText(psnId, 960, 270);

    // Calculate stats
    const winRate = totalRaces > 0 ? ((wins / totalRaces) * 100).toFixed(1) : 0;
    const poleRate = totalRaces > 0 ? ((poles / totalRaces) * 100).toFixed(1) : 0;
    const flRate = totalRaces > 0 ? ((fastestLaps / totalRaces) * 100).toFixed(1) : 0;

    // Helper function to draw card with border
    function drawCard(x, y, width, height, bgColor, borderColor) {
        ctx.fillStyle = bgColor;
        ctx.fillRect(x, y, width, height);
        ctx.strokeStyle = borderColor;
        ctx.lineWidth = 3;
        ctx.strokeRect(x, y, width, height);
    }

    // Top row - 3 cards with perfect centering
    const topY = 360;
    const topCardWidth = 480;
    const topCardHeight = 260;
    const topGap = 60;
    const topStartX = (1920 - (topCardWidth * 3 + topGap * 2)) / 2;

    // DR/Rank Card
    drawCard(topStartX, topY, topCardWidth, topCardHeight, 'rgba(0, 255, 136, 0.1)', 'rgba(0, 255, 136, 0.4)');
    ctx.fillStyle = '#00ff88';
    ctx.font = 'bold 30px Orbitron';
    ctx.textAlign = 'center';
    ctx.fillText('DRIVER RATING', topStartX + topCardWidth/2, topY + 45);

    if (dr > 0) {
        ctx.fillStyle = '#ffffff';
        ctx.font = 'bold 52px Orbitron';
        ctx.fillText(dr.toLocaleString(), topStartX + topCardWidth/2, topY + 115);
    }

    ctx.fillStyle = '#00ff88';
    ctx.font = 'bold 110px Orbitron';
    ctx.fillText(rank, topStartX + topCardWidth/2, topY + 230);

    // SR Card
    const srX = topStartX + topCardWidth + topGap;
    drawCard(srX, topY, topCardWidth, topCardHeight, 'rgba(125, 76, 219, 0.1)', 'rgba(125, 76, 219, 0.4)');
    ctx.fillStyle = '#b794f6';
    ctx.font = 'bold 30px Orbitron';
    ctx.fillText('SPORTSMANSHIP', srX + topCardWidth/2, topY + 45);
    ctx.font = 'bold 140px Orbitron';
    ctx.fillText(srGrade, srX + topCardWidth/2, topY + 185);

    // Total Races Card
    const racesX = srX + topCardWidth + topGap;
    drawCard(racesX, topY, topCardWidth, topCardHeight, 'rgba(255, 215, 0, 0.1)', 'rgba(255, 215, 0, 0.4)');
    ctx.fillStyle = '#ffd700';
    ctx.font = 'bold 30px Orbitron';
    ctx.fillText('TOTAL RACES', racesX + topCardWidth/2, topY + 45);
    ctx.fillStyle = '#ffffff';
    ctx.font = 'bold 100px Orbitron';
    ctx.fillText(totalRaces.toLocaleString(), racesX + topCardWidth/2, topY + 175);

    // Bottom row - 3 cards with perfect centering
    const bottomY = 680;
    const bottomCardWidth = 480;
    const bottomCardHeight = 220;
    const bottomGap = 60;
    const bottomStartX = (1920 - (bottomCardWidth * 3 + bottomGap * 2)) / 2;

    // Wins Card
    drawCard(bottomStartX, bottomY, bottomCardWidth, bottomCardHeight, 'rgba(255, 215, 0, 0.08)', 'rgba(255, 215, 0, 0.3)');
    ctx.fillStyle = '#ffd700';
    ctx.font = 'bold 28px Orbitron';
    ctx.textAlign = 'center';
    ctx.fillText('WINS', bottomStartX + bottomCardWidth/2, bottomY + 40);
    ctx.fillStyle = '#ffffff';
    ctx.font = 'bold 76px Orbitron';
    ctx.fillText(wins.toLocaleString(), bottomStartX + bottomCardWidth/2, bottomY + 125);
    ctx.fillStyle = '#ffd700';
    ctx.font = 'bold 40px Orbitron';
    ctx.fillText(`${winRate}%`, bottomStartX + bottomCardWidth/2, bottomY + 185);

    // Poles Card
    const polesX = bottomStartX + bottomCardWidth + bottomGap;
    drawCard(polesX, bottomY, bottomCardWidth, bottomCardHeight, 'rgba(0, 217, 255, 0.08)', 'rgba(0, 217, 255, 0.3)');
    ctx.fillStyle = '#00d9ff';
    ctx.font = 'bold 28px Orbitron';
    ctx.fillText('POLE POSITIONS', polesX + bottomCardWidth/2, bottomY + 40);
    ctx.fillStyle = '#ffffff';
    ctx.font = 'bold 76px Orbitron';
    ctx.fillText(poles.toLocaleString(), polesX + bottomCardWidth/2, bottomY + 125);
    ctx.fillStyle = '#00d9ff';
    ctx.font = 'bold 40px Orbitron';
    ctx.fillText(`${poleRate}%`, polesX + bottomCardWidth/2, bottomY + 185);

    // Fastest Laps Card
    const flX = polesX + bottomCardWidth + bottomGap;
    drawCard(flX, bottomY, bottomCardWidth, bottomCardHeight, 'rgba(255, 100, 255, 0.08)', 'rgba(255, 100, 255, 0.3)');
    ctx.fillStyle = '#ff64ff';
    ctx.font = 'bold 28px Orbitron';
    ctx.fillText('FASTEST LAPS', flX + bottomCardWidth/2, bottomY + 40);
    ctx.fillStyle = '#ffffff';
    ctx.font = 'bold 76px Orbitron';
    ctx.fillText(fastestLaps.toLocaleString(), flX + bottomCardWidth/2, bottomY + 125);
    ctx.fillStyle = '#ff64ff';
    ctx.font = 'bold 40px Orbitron';
    ctx.fillText(`${flRate}%`, flX + bottomCardWidth/2, bottomY + 185);

    // Footer with gradient background
    const footerGradient = ctx.createLinearGradient(0, 960, 0, 1050);
    footerGradient.addColorStop(0, 'rgba(0, 255, 136, 0.15)');
    footerGradient.addColorStop(1, 'rgba(0, 255, 136, 0.25)');
    ctx.fillStyle = footerGradient;
    ctx.fillRect(0, 960, 1920, 90);

    ctx.fillStyle = '#00ff88';
    ctx.font = 'bold 34px Orbitron';
    ctx.textAlign = 'left';
    ctx.fillText('🏁 Gran Turismo 7', 70, 1015);
    ctx.textAlign = 'right';
    ctx.fillText('sparkstheory.co.uk', 1850, 1015);

    // Convert canvas to blob and download
    canvas.toBlob((blob) => {
        const url = URL.createObjectURL(blob);
        const a = document.createElement('a');
        a.href = url;
        a.download = `${psnId}-GT7-Stats.png`;
        document.body.appendChild(a);
        a.click();
        document.body.removeChild(a);
        URL.revokeObjectURL(url);

        alert(`✅ Stats card downloaded!\n\nYour shareable GT7 stats card has been saved as:\n${psnId}-GT7-Stats.png\n\nShare it on social media! 🏁`);
    });
}

// ===== LEADERBOARD FUNCTIONS =====

// Submit player stats to leaderboard
async function submitToLeaderboard(psnId, userGuid, dr, rank, sr, srGrade, totalRaces, wins, poles, fastestLaps) {
    const submitBtn = document.getElementById('submitLeaderboardBtn');
    const originalText = submitBtn.textContent;

    try {
        submitBtn.textContent = 'Submitting...';
        submitBtn.disabled = true;

        // Get selected country
        const countrySelector = document.getElementById('countrySelector');
        const countryCode = countrySelector ? countrySelector.value : '';

        // Validate country selection
        if (!countryCode) {
            alert('⚠️ Please select your country before submitting to the leaderboard!');
            submitBtn.textContent = originalText;
            submitBtn.disabled = false;
            return;
        }

        // Validate stats before submission
        if (dr === 0 || totalRaces === 0) {
            alert('❌ Cannot submit to leaderboard\n\nNo Sport Mode stats found!\n\nYou need to participate in GT7 Sport Mode races first to have stats.\n\nOnce you\'ve completed some Sport Mode races, come back and submit again!');
            submitBtn.textContent = originalText;
            submitBtn.disabled = false;
            return;
        }

        // Calculate percentages
        const winPercentage = totalRaces > 0 ? ((wins / totalRaces) * 100).toFixed(2) : 0;
        const polePercentage = totalRaces > 0 ? ((poles / totalRaces) * 100).toFixed(2) : 0;
        const fastestLapPercentage = totalRaces > 0 ? ((fastestLaps / totalRaces) * 100).toFixed(2) : 0;

        // Upsert (insert or update) player data
        const { data, error } = await supabaseClient
            .from('players')
            .upsert({
                psn_id: psnId,
                user_guid: userGuid,
                country_code: countryCode,
                dr: dr,
                rank: rank,
                sr: sr,
                sr_grade: srGrade,
                total_races: totalRaces,
                wins: wins,
                poles: poles,
                fastest_laps: fastestLaps,
                win_percentage: parseFloat(winPercentage),
                pole_percentage: parseFloat(polePercentage),
                fastest_lap_percentage: parseFloat(fastestLapPercentage),
                updated_at: new Date().toISOString()
            }, {
                onConflict: 'user_guid'
            });

        if (error) throw error;

        submitBtn.textContent = '✅ Submitted to Leaderboard!';
        setTimeout(() => {
            submitBtn.textContent = originalText;
            submitBtn.disabled = false;
        }, 3000);

        // Refresh leaderboard if on that section
        await fetchLeaderboard();

        // Show success message with ranking info
        alert(`🏆 Success!\n\nYour stats have been submitted to the global leaderboard!\n\nDR: ${dr.toLocaleString()} (${rank})\nWin Rate: ${winPercentage}%\nPole Rate: ${polePercentage}%\n\nCheck the Leaderboard section to see your ranking!`);

    } catch (error) {
        console.error('Error submitting to leaderboard:', error);
        submitBtn.textContent = '❌ Error - Try Again';

        // Show detailed error message
        const errorMsg = error?.message || 'Unknown error occurred';
        const errorDetails = error?.details || '';
        const errorHint = error?.hint || '';

        let alertMessage = '❌ Error submitting to leaderboard\n\n';
        alertMessage += `Error: ${errorMsg}\n`;
        if (errorDetails) alertMessage += `Details: ${errorDetails}\n`;
        if (errorHint) alertMessage += `Hint: ${errorHint}\n`;

        alert(alertMessage);

        setTimeout(() => {
            submitBtn.textContent = originalText;
            submitBtn.disabled = false;
        }, 3000);
    }
}

// Submit player stats to leaderboard (from scraper - rank letters only)
async function submitToLeaderboardFromScraper(psnId, userGuid, rank, srGrade, totalRaces, wins, poles, fastestLaps) {
    const submitBtn = document.getElementById('submitLeaderboardBtn');
    const originalText = submitBtn.textContent;

    try {
        submitBtn.textContent = 'Submitting...';
        submitBtn.disabled = true;

        // Get selected country
        const countrySelector = document.getElementById('countrySelectorScraper');
        const countryCode = countrySelector ? countrySelector.value : '';

        // Validate country selection
        if (!countryCode) {
            alert('⚠️ Please select your country before submitting to the leaderboard!');
            submitBtn.textContent = originalText;
            submitBtn.disabled = false;
            return;
        }

        // Validate stats before submission
        if (totalRaces === 0) {
            alert('❌ Cannot submit to leaderboard\n\nNo Sport Mode stats found!\n\nYou need to participate in GT7 Sport Mode races first to have stats.\n\nOnce you\'ve completed some Sport Mode races, come back and submit again!');
            submitBtn.textContent = originalText;
            submitBtn.disabled = false;
            return;
        }

        // Calculate percentages
        const winPercentage = totalRaces > 0 ? ((wins / totalRaces) * 100).toFixed(2) : 0;
        const polePercentage = totalRaces > 0 ? ((poles / totalRaces) * 100).toFixed(2) : 0;
        const fastestLapPercentage = totalRaces > 0 ? ((fastestLaps / totalRaces) * 100).toFixed(2) : 0;

        // Upsert (insert or update) player data (without DR points, using rank letters)
        const { data, error } = await supabaseClient
            .from('players')
            .upsert({
                psn_id: psnId,
                user_guid: userGuid,
                country_code: countryCode,
                dr: 0, // No DR points from scraper
                rank: rank,
                sr: 0, // No SR value from scraper
                sr_grade: srGrade,
                total_races: totalRaces,
                wins: wins,
                poles: poles,
                fastest_laps: fastestLaps,
                win_percentage: parseFloat(winPercentage),
                pole_percentage: parseFloat(polePercentage),
                fastest_lap_percentage: parseFloat(fastestLapPercentage),
                updated_at: new Date().toISOString()
            }, {
                onConflict: 'user_guid'
            });

        if (error) throw error;

        submitBtn.textContent = '✅ Submitted to Leaderboard!';
        setTimeout(() => {
            submitBtn.textContent = originalText;
            submitBtn.disabled = false;
        }, 3000);

        // Refresh leaderboard if on that section
        await fetchLeaderboard();

        // Show success message with ranking info
        alert(`🏆 Success!\n\nYour stats have been submitted to the global leaderboard!\n\nRank: ${rank}\nSR: ${srGrade}\nWin Rate: ${winPercentage}%\nPole Rate: ${polePercentage}%\n\nCheck the Leaderboard section to see your ranking!`);

    } catch (error) {
        console.error('Error submitting to leaderboard:', error);
        submitBtn.textContent = '❌ Error - Try Again';

        // Show detailed error message
        const errorMsg = error?.message || 'Unknown error occurred';
        const errorDetails = error?.details || '';
        const errorHint = error?.hint || '';

        let alertMessage = '❌ Error submitting to leaderboard\n\n';
        alertMessage += `Error: ${errorMsg}\n`;
        if (errorDetails) alertMessage += `Details: ${errorDetails}\n`;
        if (errorHint) alertMessage += `Hint: ${errorHint}\n`;

        alert(alertMessage);

        setTimeout(() => {
            submitBtn.textContent = originalText;
            submitBtn.disabled = false;
        }, 3000);
    }
}

// Fetch and display leaderboard
let currentSort = 'dr';
let leaderboardData = [];
let currentPage = 1;
const itemsPerPage = 10;
let searchFilter = '';

// ===== RIVAL TRACKING SYSTEM =====
const MAX_RIVALS = 5;

function getRivals() {
    const rivals = localStorage.getItem('gt7_rivals');
    return rivals ? JSON.parse(rivals) : [];
}

function isRival(userGuid) {
    const rivals = getRivals();
    return rivals.some(r => r.user_guid === userGuid);
}

function addRival(player) {
    const rivals = getRivals();

    // Check if already a rival
    if (isRival(player.user_guid)) {
        alert('This player is already in your rivals list!');
        return false;
    }

    // Check max limit
    if (rivals.length >= MAX_RIVALS) {
        alert(`Maximum of ${MAX_RIVALS} rivals allowed. Remove one first.`);
        return false;
    }

    // Add rival with timestamp
    rivals.push({
        user_guid: player.user_guid,
        psn_id: player.psn_id,
        country_code: player.country_code,
        added_at: Date.now()
    });

    localStorage.setItem('gt7_rivals', JSON.stringify(rivals));
    displayLeaderboard(); // Refresh to show updated UI
    return true;
}

function removeRival(userGuid) {
    const rivals = getRivals();
    const filtered = rivals.filter(r => r.user_guid !== userGuid);
    localStorage.setItem('gt7_rivals', JSON.stringify(filtered));
    displayLeaderboard(); // Refresh to show updated UI
}

function getRivalPlayerData(userGuid) {
    return leaderboardData.find(p => p.user_guid === userGuid);
}

async function fetchLeaderboard(sortBy = 'dr') {
    const leaderboardResults = document.getElementById('leaderboardResults');

    try {
        leaderboardResults.innerHTML = `
            <div style="text-align: center; padding: 3rem; color: var(--color-text-muted);">
                <p style="font-size: 1.2rem;">Loading leaderboard...</p>
            </div>
        `;

        // Fetch all players
        const { data, error } = await supabaseClient
            .from('players')
            .select('*')
            .order(sortBy, { ascending: false });

        if (error) throw error;

        leaderboardData = data || [];
        currentSort = sortBy;
        displayLeaderboard();

    } catch (error) {
        console.error('Error fetching leaderboard:', error);
        leaderboardResults.innerHTML = `
            <div style="background: rgba(239,68,68,0.1); border: 2px solid rgba(239,68,68,0.3); border-radius: 12px; padding: 2rem; text-align: center;">
                <p style="color: #fca5a5; font-size: 1.2rem;">Error loading leaderboard</p>
                <p style="color: var(--color-text-muted); margin-top: 1rem;">Please try again later</p>
            </div>
        `;
    }
}

function sortLeaderboard(sortBy) {
    currentSort = sortBy;
    currentPage = 1; // Reset to first page when sorting

    // Sort the existing data
    leaderboardData.sort((a, b) => {
        return (b[sortBy] || 0) - (a[sortBy] || 0);
    });

    displayLeaderboard();
}

function filterLeaderboard() {
    const searchInput = document.getElementById('leaderboardSearch');
    searchFilter = searchInput ? searchInput.value.toLowerCase().trim() : '';
    currentPage = 1; // Reset to first page when filtering
    displayLeaderboard();
}

function getFilteredLeaderboardData() {
    if (!searchFilter) {
        return leaderboardData;
    }

    return leaderboardData.filter(player => {
        const psnName = (player.psn_id || '').toLowerCase();
        const rank = (player.rank || '').toLowerCase();
        return psnName.includes(searchFilter) || rank.includes(searchFilter);
    });
}

function changePage(direction) {
    const totalPages = Math.ceil(leaderboardData.length / itemsPerPage);

    if (direction === 'prev' && currentPage > 1) {
        currentPage--;
    } else if (direction === 'next' && currentPage < totalPages) {
        currentPage++;
    }

    displayLeaderboard();
}

// ===== CHAMPION SCORE SYSTEM =====
function calculateChampionScore(player) {
    // Minimum 10 races to qualify
    if (!player.total_races || player.total_races < 10) {
        return null;
    }

    // Calculate component scores (0-100 scale)
    const drScore = Math.min((player.dr || 0) / 500, 1) * 100;
    const winRate = player.total_races > 0 ? (player.wins || 0) / player.total_races * 100 : 0;
    const srScore = (player.sr || 0) / 99 * 100;
    const poleRate = player.total_races > 0 ? (player.poles || 0) / player.total_races * 100 : 0;
    const flRate = player.total_races > 0 ? (player.fastest_laps || 0) / player.total_races * 100 : 0;

    // Apply weights: DR(40%) + Win(25%) + SR(15%) + Pole(10%) + FL(10%)
    const championScore = (
        drScore * 0.40 +
        winRate * 0.25 +
        srScore * 0.15 +
        poleRate * 0.10 +
        flRate * 0.10
    );

    return {
        total: championScore,
        breakdown: {
            dr: drScore,
            winRate: winRate,
            sr: srScore,
            poleRate: poleRate,
            flRate: flRate
        }
    };
}

function getChampionTier(score) {
    if (score >= 80) return { name: 'Legend', icon: '👑', color: '#ffd700' };
    if (score >= 70) return { name: 'Champion', icon: '🏆', color: '#00ff88' };
    if (score >= 60) return { name: 'Elite', icon: '🥇', color: '#c0c0c0' };
    if (score >= 50) return { name: 'Master', icon: '🥈', color: '#cd7f32' };
    if (score >= 40) return { name: 'Expert', icon: '⭐', color: '#60a5fa' };
    if (score >= 30) return { name: 'Skilled', icon: '🔷', color: '#94a3b8' };
    return { name: 'Contender', icon: '🔸', color: '#64748b' };
}

// DR History Cache for Trend Graphs
const drHistoryCache = {};

// Rank change tracking
function saveLeaderboardPositions(leaderboardData) {
    const positions = {};
    leaderboardData.forEach((player, index) => {
        positions[player.user_guid] = index + 1; // 1-based ranking
    });
    localStorage.setItem('leaderboard_positions', JSON.stringify(positions));
    localStorage.setItem('leaderboard_timestamp', Date.now().toString());
}

function getPositionChange(userGuid, currentPosition) {
    try {
        const savedPositions = localStorage.getItem('leaderboard_positions');
        if (!savedPositions) return null;

        const positions = JSON.parse(savedPositions);
        const previousPosition = positions[userGuid];

        if (!previousPosition) return null;

        const change = previousPosition - currentPosition; // Positive = moved up
        return change;
    } catch (error) {
        console.error('Error getting position change:', error);
        return null;
    }
}

function getRankChangeIndicator(change) {
    if (!change || change === 0) return '';

    const isPositive = change > 0;
    const absChange = Math.abs(change);
    const color = isPositive ? '#00ff88' : '#ff4444';
    const arrow = isPositive ? '↑' : '↓';
    const prefix = isPositive ? '+' : '';

    return `<span style="color: ${color}; font-size: 0.8rem; font-weight: 600; margin-left: 0.5rem; animation: rankChange 0.5s ease-out;">${arrow}${absChange}</span>`;
}

// Fetch DR history for a player
async function fetchDRHistory(userGuid, psnId) {
    // Check cache first
    const cacheKey = `${userGuid}_${psnId}`;
    if (drHistoryCache[cacheKey]) {
        return drHistoryCache[cacheKey];
    }

    try {
        const apiUrl = `https://gtstats.live/api/getDriverStatsHistory?user_id=${userGuid}&psn=${encodeURIComponent(psnId)}`;
        const proxyUrl = `https://api.allorigins.win/get?url=${encodeURIComponent(apiUrl)}`;

        const response = await fetch(proxyUrl);
        const proxyData = await response.json();
        const data = JSON.parse(proxyData.contents);

        // Cache the result
        drHistoryCache[cacheKey] = data;
        return data;
    } catch (error) {
        console.error('Error fetching DR history:', error);
        return null;
    }
}

// Create sparkline SVG for DR trend
function createSparkline(historyData, width = 80, height = 30) {
    if (!historyData || typeof historyData !== 'object') {
        return '<svg width="80" height="30"></svg>'; // Empty SVG
    }

    // Convert history object to array and get last 30 data points
    // API returns newest first, so reverse to get chronological order (oldest to newest)
    const dataPoints = Object.values(historyData)
        .map(entry => entry.dr || 0)
        .filter(dr => dr > 0)
        .slice(-30) // Last 30 data points
        .reverse(); // Reverse to get oldest-to-newest order for plotting

    if (dataPoints.length < 2) {
        return '<svg width="80" height="30"></svg>'; // Need at least 2 points
    }

    // Calculate min/max for scaling
    const minDR = Math.min(...dataPoints);
    const maxDR = Math.max(...dataPoints);
    const range = maxDR - minDR || 1; // Avoid division by zero

    // Create SVG path
    const stepX = width / (dataPoints.length - 1);
    const points = dataPoints.map((dr, i) => {
        const x = i * stepX;
        const y = height - ((dr - minDR) / range * (height - 4)) - 2; // 2px padding
        return `${x},${y}`;
    }).join(' ');

    // Determine color based on trend (first vs last)
    // Now first = oldest, last = newest
    const trend = dataPoints[dataPoints.length - 1] - dataPoints[0];
    const color = trend >= 0 ? '#00ff88' : '#ff4444';

    return `<svg width="${width}" height="${height}" style="display: block;">
        <polyline
            points="${points}"
            fill="none"
            stroke="${color}"
            stroke-width="2"
            stroke-linecap="round"
            stroke-linejoin="round"
            opacity="0.8"
        />
    </svg>`;
}

// Calculate similarity between two players
function calculateSimilarity(player1, player2) {
    // Normalize DR (0-100000 range)
    const drDiff = Math.abs((player1.dr || 0) - (player2.dr || 0)) / 100000;

    // Win rate difference
    const winDiff = Math.abs((player1.win_percentage || 0) - (player2.win_percentage || 0)) / 100;

    // Pole rate difference
    const poleDiff = Math.abs((player1.pole_percentage || 0) - (player2.pole_percentage || 0)) / 100;

    // FL rate difference
    const flDiff = Math.abs((player1.fastest_lap_percentage || 0) - (player2.fastest_lap_percentage || 0)) / 100;

    // SR grade similarity (convert to number)
    const srGrades = { 'E': 0, 'D': 1, 'C': 2, 'B': 3, 'A': 4, 'S': 5 };
    const sr1 = srGrades[player1.sr_grade] || 0;
    const sr2 = srGrades[player2.sr_grade] || 0;
    const srDiff = Math.abs(sr1 - sr2) / 5;

    // Weighted similarity score (lower is more similar)
    // DR is most important, then win rate, then others
    const similarity = (drDiff * 0.4) + (winDiff * 0.25) + (poleDiff * 0.15) + (flDiff * 0.15) + (srDiff * 0.05);

    return 1 - similarity; // Convert to similarity score (higher is more similar)
}

// Find similar drivers
function findSimilarDrivers(targetPlayer, allPlayers, limit = 5) {
    return allPlayers
        .filter(p => p.user_guid !== targetPlayer.user_guid) // Exclude the target player
        .map(p => ({
            player: p,
            similarity: calculateSimilarity(targetPlayer, p)
        }))
        .sort((a, b) => b.similarity - a.similarity) // Sort by similarity descending
        .slice(0, limit); // Take top N
}

// Show similar drivers modal
function showSimilarDrivers(player) {
    const similarDrivers = findSimilarDrivers(player, leaderboardData, 5);
    const modalId = `similar-drivers-modal-${Date.now()}`;

    let html = `
        <div id="${modalId}" style="position: fixed; top: 0; left: 0; right: 0; bottom: 0; background: rgba(0,0,0,0.8); display: flex; align-items: center; justify-content: center; z-index: 10000; padding: 1rem;" onclick="this.remove()">
            <div style="background: linear-gradient(135deg, #1a1a2e 0%, #16213e 100%); border: 2px solid rgba(0,255,136,0.3); border-radius: 16px; max-width: 600px; width: 100%; max-height: 80vh; overflow-y: auto; padding: 2rem;" onclick="event.stopPropagation()">
                <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 1.5rem;">
                    <h3 style="color: var(--color-primary); font-size: 1.5rem; margin: 0;">Similar Drivers to ${player.psn_id}</h3>
                    <button onclick="document.getElementById('${modalId}').remove()" style="background: rgba(255,255,255,0.1); border: 1px solid rgba(255,255,255,0.2); color: white; padding: 0.5rem 1rem; border-radius: 8px; cursor: pointer; font-size: 0.9rem; transition: all 0.2s;" onmouseover="this.style.background='rgba(255,255,255,0.2)'" onmouseout="this.style.background='rgba(255,255,255,0.1)'">Close</button>
                </div>

                <div style="background: rgba(0,255,136,0.05); border: 1px solid rgba(0,255,136,0.2); border-radius: 12px; padding: 1rem; margin-bottom: 1.5rem;">
                    <div style="font-size: 0.85rem; color: var(--color-text-muted); margin-bottom: 0.5rem;">YOUR STATS</div>
                    <div style="display: grid; grid-template-columns: repeat(auto-fit, minmax(120px, 1fr)); gap: 0.75rem;">
                        <div><span style="color: var(--color-primary); font-weight: 700;">${player.rank || 'E'}</span> <span style="color: var(--color-text-muted); font-size: 0.85rem;">Rank</span></div>
                        <div><span style="color: var(--color-primary); font-weight: 700;">${player.win_percentage?.toFixed(1) || 0}%</span> <span style="color: var(--color-text-muted); font-size: 0.85rem;">Win</span></div>
                        <div><span style="color: var(--color-secondary); font-weight: 700;">${player.pole_percentage?.toFixed(1) || 0}%</span> <span style="color: var(--color-text-muted); font-size: 0.85rem;">Pole</span></div>
                        <div><span style="color: var(--color-primary); font-weight: 700;">${player.fastest_lap_percentage?.toFixed(1) || 0}%</span> <span style="color: var(--color-text-muted); font-size: 0.85rem;">FL</span></div>
                    </div>
                </div>

                <div style="color: var(--color-text-muted); font-size: 0.85rem; margin-bottom: 1rem;">Players with similar racing profiles (match score out of 100%):</div>

                <div style="display: flex; flex-direction: column; gap: 0.75rem;">
    `;

    similarDrivers.forEach((item, index) => {
        const p = item.player;
        const matchScore = (item.similarity * 100).toFixed(0);
        const countryFlag = p.country_code ? getCountryFlag(p.country_code) + ' ' : '';

        html += `
            <div style="background: rgba(255,255,255,0.03); border: 1px solid rgba(255,255,255,0.1); border-radius: 12px; padding: 1rem; transition: all 0.2s;" onmouseover="this.style.background='rgba(255,255,255,0.06)'" onmouseout="this.style.background='rgba(255,255,255,0.03)'">
                <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 0.75rem;">
                    <div style="font-weight: 700; color: var(--color-primary); font-size: 1.1rem;">${countryFlag}${p.psn_id}</div>
                    <div style="background: linear-gradient(135deg, rgba(0,255,136,0.2), rgba(14,165,233,0.2)); padding: 0.25rem 0.75rem; border-radius: 20px; font-size: 0.85rem; color: white; font-weight: 600;">${matchScore}% Match</div>
                </div>
                <div style="display: grid; grid-template-columns: repeat(auto-fit, minmax(100px, 1fr)); gap: 0.5rem; font-size: 0.9rem;">
                    <div><span style="color: var(--color-text-muted);">Rank:</span> <span style="color: var(--color-primary); font-weight: 600;">${p.rank || 'E'}</span></div>
                    <div><span style="color: var(--color-text-muted);">Win:</span> <span style="color: var(--color-primary); font-weight: 600;">${p.win_percentage?.toFixed(1) || 0}%</span></div>
                    <div><span style="color: var(--color-text-muted);">Pole:</span> <span style="color: var(--color-secondary); font-weight: 600;">${p.pole_percentage?.toFixed(1) || 0}%</span></div>
                    <div><span style="color: var(--color-text-muted);">FL:</span> <span style="color: var(--color-primary); font-weight: 600;">${p.fastest_lap_percentage?.toFixed(1) || 0}%</span></div>
                </div>
            </div>
        `;
    });

    html += `
                </div>
            </div>
        </div>
    `;

    document.body.insertAdjacentHTML('beforeend', html);
}

function displayLeaderboard() {
    const leaderboardResults = document.getElementById('leaderboardResults');

    if (!leaderboardData || leaderboardData.length === 0) {
        leaderboardResults.innerHTML = `
            <div style="background: rgba(255,255,255,0.05); border: 1px solid rgba(255,255,255,0.1); border-radius: 12px; padding: 3rem; text-align: center;">
                <p style="color: var(--color-text-muted); font-size: 1.2rem; margin-bottom: 1rem;">No players on the leaderboard yet</p>
                <p style="color: var(--color-text-muted);">Be the first to submit your stats!</p>
            </div>
        `;
        return;
    }

    // Get filtered data
    const filteredData = getFilteredLeaderboardData();

    // Show "no results" message if filter returns empty
    if (filteredData.length === 0) {
        leaderboardResults.innerHTML = `
            <div style="background: rgba(255,255,255,0.05); border: 1px solid rgba(255,255,255,0.1); border-radius: 12px; padding: 3rem; text-align: center;">
                <p style="color: var(--color-text-muted); font-size: 1.2rem; margin-bottom: 1rem;">No players found matching "${searchFilter}"</p>
                <p style="color: var(--color-text-muted);">Try a different search term</p>
            </div>
        `;
        return;
    }

    // Calculate pagination with filtered data
    const totalPages = Math.ceil(filteredData.length / itemsPerPage);
    const startIndex = (currentPage - 1) * itemsPerPage;
    const endIndex = startIndex + itemsPerPage;
    const pageData = filteredData.slice(startIndex, endIndex);

    const sortLabels = {
        dr: 'Driver Rating',
        win_percentage: 'Win Percentage',
        pole_percentage: 'Pole Percentage',
        fastest_lap_percentage: 'Fastest Lap Percentage',
        total_races: 'Total Races'
    };

    // Rivals Section
    let rivalsHtml = '';
    const rivals = getRivals();
    if (rivals.length > 0) {
        const rivalCards = rivals.map(rival => {
            const rivalPlayer = getRivalPlayerData(rival.user_guid);
            if (!rivalPlayer) {
                return `<div style="flex: 1; min-width: 200px; max-width: 250px; background: rgba(255,255,255,0.03); border: 2px solid rgba(255,215,0,0.3); border-radius: 12px; padding: 1.5rem; text-align: center;">
                    <div style="color: var(--color-text-muted); font-size: 0.9rem;">Player not found</div>
                    <div style="color: var(--color-primary); font-weight: 700; margin: 0.5rem 0;">${rival.psn_id}</div>
                    <button onclick='removeRival("${rival.user_guid}")' style="background: rgba(255,0,0,0.1); border: 1px solid #ff4444; color: #ff4444; padding: 0.4rem 1rem; border-radius: 8px; cursor: pointer; font-size: 0.75rem; margin-top: 1rem;">Remove</button>
                </div>`;
            }

            const rivalPosition = filteredData.findIndex(p => p.user_guid === rival.user_guid) + 1;
            const countryFlag = rivalPlayer.country_code ? getCountryFlag(rivalPlayer.country_code) + ' ' : '';

            return `<div style="flex: 1; min-width: 200px; max-width: 250px; background: linear-gradient(135deg, rgba(255,215,0,0.1), rgba(255,165,0,0.05)); border: 2px solid rgba(255,215,0,0.5); border-radius: 12px; padding: 1.5rem; text-align: center; position: relative;">
                <div style="position: absolute; top: 0.5rem; right: 0.5rem; font-size: 1.5rem;">⭐</div>
                <div style="color: #ffd700; font-weight: 900; font-size: 2rem; margin-bottom: 0.5rem;">#${rivalPosition || '?'}</div>
                <div style="color: var(--color-primary); font-weight: 700; font-size: 1.1rem; margin-bottom: 1rem;">${countryFlag}${rivalPlayer.psn_id}</div>
                <div style="background: rgba(255,255,255,0.05); border-radius: 8px; padding: 1rem; margin-bottom: 0.5rem;">
                    <div style="color: var(--color-primary); font-weight: 800; font-size: 1.5rem; line-height: 1;">${rivalPlayer.rank || 'E'}</div>
                    <div style="color: var(--text-color); font-size: 0.9rem; margin-top: 0.25rem;">${rivalPlayer.dr?.toLocaleString() || 0} DR</div>
                </div>
                <div style="display: flex; gap: 0.5rem; justify-content: center; margin-top: 0.75rem;">
                    <div style="flex: 1; background: rgba(255,255,255,0.03); border-radius: 6px; padding: 0.4rem;">
                        <div style="color: var(--color-text-muted); font-size: 0.65rem;">SR</div>
                        <div style="color: var(--color-secondary); font-weight: 700; font-size: 0.9rem;">${rivalPlayer.sr_grade || 'E'}</div>
                    </div>
                    <div style="flex: 1; background: rgba(255,255,255,0.03); border-radius: 6px; padding: 0.4rem;">
                        <div style="color: var(--color-text-muted); font-size: 0.65rem;">Win%</div>
                        <div style="color: var(--color-primary); font-weight: 700; font-size: 0.9rem;">${rivalPlayer.win_percentage?.toFixed(1) || 0}%</div>
                    </div>
                </div>
                <button onclick='removeRival("${rival.user_guid}")' style="background: rgba(255,255,255,0.05); border: 1px solid rgba(255,255,255,0.15); color: var(--color-text-muted); padding: 0.4rem 1rem; border-radius: 8px; cursor: pointer; font-size: 0.75rem; margin-top: 1rem; transition: all 0.2s;" onmouseover="this.style.background='rgba(255,0,0,0.1)'; this.style.borderColor='#ff4444'; this.style.color='#ff4444'" onmouseout="this.style.background='rgba(255,255,255,0.05)'; this.style.borderColor='rgba(255,255,255,0.15)'; this.style.color='var(--color-text-muted)'">Unpin</button>
            </div>`;
        }).join('');

        rivalsHtml = `
            <div style="margin-bottom: 3rem; padding: 2rem; background: linear-gradient(135deg, rgba(255,215,0,0.05), rgba(255,165,0,0.02)); border: 2px solid rgba(255,215,0,0.2); border-radius: 16px;">
                <h3 style="text-align: center; color: #ffd700; font-size: 1.3rem; margin-bottom: 1.5rem; text-transform: uppercase; letter-spacing: 2px;">
                    ⭐ Your Rivals (${rivals.length}/${MAX_RIVALS})
                </h3>
                <div style="display: flex; justify-content: center; gap: 1.5rem; flex-wrap: wrap;">
                    ${rivalCards}
                </div>
                <p style="text-align: center; color: var(--color-text-muted); font-size: 0.85rem; margin-top: 1.5rem; font-style: italic;">
                    Track up to ${MAX_RIVALS} rivals and monitor their progress on the leaderboard
                </p>
            </div>
        `;
    }

    // Top 3 Podium Showcase
    let podiumHtml = '';
    if (leaderboardData.length >= 3) {
        const top3 = leaderboardData.slice(0, 3);

        // Helper function for trend arrow in podium
        const getTrendArrow = (player) => {
            if (player.dr_change !== undefined && player.dr_change !== null && player.dr_change !== 0) {
                const changeColor = player.dr_change > 0 ? '#00ff88' : '#ff4444';
                const arrowIcon = player.dr_change > 0 ? '↑' : '↓';
                const changeSign = player.dr_change > 0 ? '+' : '';
                return `<div style="color: ${changeColor}; font-size: 0.85rem; margin-top: 0.25rem;">${arrowIcon} ${changeSign}${player.dr_change}</div>`;
            }
            return '';
        };

        // Determine podium title and stat display based on current sort
        let podiumTitle = '🏆 Top 3 Champions 🏆';
        let getMainStat = (player) => {
            if (currentSort === 'dr') {
                return `<div style="color: var(--color-primary); font-weight: 800; font-size: 2.5rem; line-height: 1;">${player.rank || 'E'}</div>
                        <div style="color: var(--text-color); font-size: 1.1rem; margin-top: 0.25rem;">${player.dr?.toLocaleString() || 0} DR</div>
                        ${getTrendArrow(player)}`;
            } else if (currentSort === 'win_percentage') {
                return `<div style="color: var(--color-primary); font-weight: 800; font-size: 3rem; line-height: 1;">${player.win_percentage?.toFixed(1) || 0}%</div>
                        <div style="color: var(--text-color); font-size: 1rem; margin-top: 0.25rem;">${player.wins || 0} / ${player.total_races || 0} Wins</div>`;
            } else if (currentSort === 'pole_percentage') {
                return `<div style="color: var(--color-primary); font-weight: 800; font-size: 3rem; line-height: 1;">${player.pole_percentage?.toFixed(1) || 0}%</div>
                        <div style="color: var(--text-color); font-size: 1rem; margin-top: 0.25rem;">${player.poles || 0} / ${player.total_races || 0} Poles</div>`;
            } else if (currentSort === 'fastest_lap_percentage') {
                return `<div style="color: var(--color-primary); font-weight: 800; font-size: 3rem; line-height: 1;">${player.fastest_lap_percentage?.toFixed(1) || 0}%</div>
                        <div style="color: var(--text-color); font-size: 1rem; margin-top: 0.25rem;">${player.fastest_laps || 0} / ${player.total_races || 0} FLs</div>`;
            } else if (currentSort === 'total_races') {
                return `<div style="color: var(--color-primary); font-weight: 800; font-size: 3rem; line-height: 1;">${player.total_races?.toLocaleString() || 0}</div>
                        <div style="color: var(--text-color); font-size: 1rem; margin-top: 0.25rem;">Total Races</div>`;
            }
        };

        // Update title based on sort
        if (currentSort === 'win_percentage') {
            podiumTitle = '🏆 Top 3 Win Rate Leaders 🏆';
        } else if (currentSort === 'pole_percentage') {
            podiumTitle = '🏆 Top 3 Pole Position Masters 🏆';
        } else if (currentSort === 'fastest_lap_percentage') {
            podiumTitle = '🏆 Top 3 Fastest Lap Experts 🏆';
        } else if (currentSort === 'total_races') {
            podiumTitle = '🏆 Top 3 Most Active Racers 🏆';
        }

        const flag1 = top3[0].country_code ? getCountryFlag(top3[0].country_code) + ' ' : '';
        const flag2 = top3[1].country_code ? getCountryFlag(top3[1].country_code) + ' ' : '';
        const flag3 = top3[2].country_code ? getCountryFlag(top3[2].country_code) + ' ' : '';

        podiumHtml = `
            <div style="margin-bottom: 3rem;">
                <h3 style="text-align: center; color: var(--color-primary); font-size: 1.5rem; margin-bottom: 2rem; text-transform: uppercase; letter-spacing: 2px;">
                    ${podiumTitle}
                </h3>
                <div style="display: flex; justify-content: center; align-items: flex-end; gap: 2rem; flex-wrap: wrap; max-width: 900px; margin: 0 auto;">
                    <!-- 2nd Place -->
                    <div style="flex: 1; min-width: 200px; max-width: 250px; background: linear-gradient(135deg, rgba(192,192,192,0.2), rgba(192,192,192,0.05)); border: 2px solid #c0c0c0; border-radius: 16px; padding: 2rem 1.5rem; text-align: center; transform: translateY(20px);">
                        <div style="font-size: 3rem; margin-bottom: 0.5rem;">🥈</div>
                        <div style="color: #c0c0c0; font-weight: 900; font-size: 2rem; margin-bottom: 0.5rem;">#2</div>
                        <div style="color: var(--color-primary); font-weight: 700; font-size: 1.3rem; margin-bottom: 1rem;">${flag2}${top3[1].psn_id}</div>
                        <div style="background: rgba(255,255,255,0.05); border-radius: 8px; padding: 1rem; margin-bottom: 0.5rem;">
                            ${getMainStat(top3[1])}
                        </div>
                    </div>

                    <!-- 1st Place (Champion) -->
                    <div style="flex: 1; min-width: 200px; max-width: 270px; background: linear-gradient(135deg, rgba(255,215,0,0.3), rgba(255,215,0,0.05)); border: 3px solid #ffd700; border-radius: 16px; padding: 2.5rem 1.5rem; text-align: center; box-shadow: 0 8px 32px rgba(255,215,0,0.3);">
                        <div style="font-size: 4rem; margin-bottom: 0.5rem;">🥇</div>
                        <div style="color: #ffd700; font-weight: 900; font-size: 2.5rem; margin-bottom: 0.5rem; text-shadow: 0 0 20px rgba(255,215,0,0.5);">#1</div>
                        <div style="color: var(--color-primary); font-weight: 900; font-size: 1.5rem; margin-bottom: 1rem;">${flag1}${top3[0].psn_id}</div>
                        <div style="background: rgba(255,255,255,0.1); border-radius: 8px; padding: 1.25rem; margin-bottom: 0.5rem;">
                            ${getMainStat(top3[0])}
                        </div>
                    </div>

                    <!-- 3rd Place -->
                    <div style="flex: 1; min-width: 200px; max-width: 250px; background: linear-gradient(135deg, rgba(205,127,50,0.2), rgba(205,127,50,0.05)); border: 2px solid #cd7f32; border-radius: 16px; padding: 2rem 1.5rem; text-align: center; transform: translateY(20px);">
                        <div style="font-size: 3rem; margin-bottom: 0.5rem;">🥉</div>
                        <div style="color: #cd7f32; font-weight: 900; font-size: 2rem; margin-bottom: 0.5rem;">#3</div>
                        <div style="color: var(--color-primary); font-weight: 700; font-size: 1.3rem; margin-bottom: 1rem;">${flag3}${top3[2].psn_id}</div>
                        <div style="background: rgba(255,255,255,0.05); border-radius: 8px; padding: 1rem; margin-bottom: 0.5rem;">
                            ${getMainStat(top3[2])}
                        </div>
                    </div>
                </div>
            </div>
        `;
    }

    let html = rivalsHtml + podiumHtml + `
        <div style="margin-bottom: 1.5rem; text-align: center;">
            <p style="color: var(--color-text-muted); font-size: 1rem;">
                Sorted by: <span style="color: var(--color-primary); font-weight: 700;">${sortLabels[currentSort]}</span>
            </p>
            <p style="color: var(--color-text-muted); font-size: 0.9rem; margin-top: 0.5rem;">
                ${leaderboardData.length} player${leaderboardData.length !== 1 ? 's' : ''} ranked
            </p>
        </div>

        <!-- Desktop Table View -->
        <div style="display: none; overflow-x: auto; background: rgba(255,255,255,0.03); border-radius: 12px; border: 1px solid rgba(255,255,255,0.1);" class="desktop-leaderboard">
            <table style="width: 100%; border-collapse: collapse;">
                <thead>
                    <tr style="background: linear-gradient(180deg, rgba(96,197,255,0.15) 0%, rgba(14,165,233,0.15) 50%, rgba(96,197,255,0.15) 100%); border-bottom: 2px solid rgba(0,255,136,0.3);">
                        <th style="padding: 0.6rem 1rem; text-align: center; color: var(--color-primary); font-size: 0.75rem; text-transform: uppercase; letter-spacing: 1px;">#</th>
                        <th style="padding: 0.6rem 1rem; text-align: left; color: var(--color-primary); font-size: 0.75rem; text-transform: uppercase; letter-spacing: 1px;">PSN ID</th>
                        <th style="padding: 0.6rem 1rem; text-align: center; color: var(--color-primary); font-size: 0.75rem; text-transform: uppercase; letter-spacing: 1px;">DR</th>
                        <th style="padding: 0.6rem 1rem; text-align: center; color: var(--color-primary); font-size: 0.75rem; text-transform: uppercase; letter-spacing: 1px;">Trend</th>
                        <th style="padding: 0.6rem 1rem; text-align: center; color: var(--color-primary); font-size: 0.75rem; text-transform: uppercase; letter-spacing: 1px;">Rank</th>
                        <th style="padding: 0.6rem 1rem; text-align: center; color: var(--color-primary); font-size: 0.75rem; text-transform: uppercase; letter-spacing: 1px;">SR</th>
                        <th style="padding: 0.6rem 1rem; text-align: center; color: var(--color-primary); font-size: 0.75rem; text-transform: uppercase; letter-spacing: 1px;">Races</th>
                        <th style="padding: 0.6rem 1rem; text-align: center; color: var(--color-primary); font-size: 0.75rem; text-transform: uppercase; letter-spacing: 1px;">Win %</th>
                        <th style="padding: 0.6rem 1rem; text-align: center; color: var(--color-primary); font-size: 0.75rem; text-transform: uppercase; letter-spacing: 1px;">Pole %</th>
                        <th style="padding: 0.6rem 1rem; text-align: center; color: var(--color-primary); font-size: 0.75rem; text-transform: uppercase; letter-spacing: 1px;">FL %</th>
                        <th style="padding: 0.6rem 1rem; text-align: center; color: var(--color-primary); font-size: 0.75rem; text-transform: uppercase; letter-spacing: 1px;">Similar</th>
                    </tr>
                </thead>
                <tbody>
    `;

    pageData.forEach((player, pageIndex) => {
        const index = startIndex + pageIndex; // Global index for ranking
        const rankColor = index === 0 ? '#ffd700' : index === 1 ? '#c0c0c0' : index === 2 ? '#cd7f32' : 'var(--color-text-muted)';
        const rankIcon = index === 0 ? '🥇' : index === 1 ? '🥈' : index === 2 ? '🥉' : '';

        // DR Trend Arrow
        let trendArrow = '';
        if (player.dr_change !== undefined && player.dr_change !== null && player.dr_change !== 0) {
            const changeColor = player.dr_change > 0 ? '#00ff88' : '#ff4444';
            const arrowIcon = player.dr_change > 0 ? '↑' : '↓';
            const changeSign = player.dr_change > 0 ? '+' : '';
            trendArrow = `<span style="color: ${changeColor}; font-size: 0.9rem; margin-left: 0.5rem;">${arrowIcon} ${changeSign}${player.dr_change}</span>`;
        }

        // Country Flag
        const countryFlag = player.country_code ? getCountryFlag(player.country_code) + ' ' : '';

        // Special emoji for specific players
        const specialEmoji = player.psn_id === 'marris_GT7' ? ' 🎂' : '';

        // Position change tracking
        const currentPosition = index + 1;
        const positionChange = getPositionChange(player.user_guid, currentPosition);
        const rankChangeIndicator = getRankChangeIndicator(positionChange);

        // Rival tracking
        const playerIsRival = isRival(player.user_guid);

        // Subtle gradient for each row (highlight rivals)
        const rowGradient = playerIsRival
            ? `linear-gradient(180deg, rgba(255,215,0,0.08) 0%, rgba(255,165,0,0.08) 50%, rgba(255,215,0,0.08) 100%)`
            : `linear-gradient(180deg, rgba(96,197,255,0.02) 0%, rgba(14,165,233,0.02) 50%, rgba(96,197,255,0.02) 100%)`;

        const rowHoverGradient = playerIsRival
            ? `linear-gradient(180deg, rgba(255,215,0,0.15) 0%, rgba(255,165,0,0.15) 50%, rgba(255,215,0,0.15) 100%)`
            : `linear-gradient(180deg, rgba(96,197,255,0.08) 0%, rgba(14,165,233,0.08) 50%, rgba(96,197,255,0.08) 100%)`;

        const rowId = `row-${player.user_guid}`;
        const trendCellId = `trend-${player.user_guid}`;
        const tagsHTML = getTagsHTML(player.user_guid);

        // Rival button HTML
        const rivalButton = playerIsRival
            ? `<button onclick='event.stopPropagation(); removeRival("${player.user_guid}")' style="background: rgba(255,215,0,0.1); border: 1px solid rgba(255,215,0,0.4); color: #ffd700; padding: 0.15rem 0.5rem; border-radius: 12px; cursor: pointer; font-size: 0.65rem; transition: all 0.2s; text-transform: uppercase; letter-spacing: 0.5px; font-weight: 600;" onmouseover="this.style.background='rgba(255,0,0,0.1)'; this.style.borderColor='#ff4444'; this.style.color='#ff4444'" onmouseout="this.style.background='rgba(255,215,0,0.1)'; this.style.borderColor='rgba(255,215,0,0.4)'; this.style.color='#ffd700'" title="Remove from rivals">⭐ rival</button>`
            : `<button onclick='event.stopPropagation(); addRival(${JSON.stringify(player).replace(/'/g, "\\'")} )' style="background: rgba(255,255,255,0.03); border: 1px solid rgba(255,255,255,0.15); color: var(--color-text-muted); padding: 0.15rem 0.5rem; border-radius: 12px; cursor: pointer; font-size: 0.65rem; transition: all 0.2s; text-transform: uppercase; letter-spacing: 0.5px; font-weight: 600;" onmouseover="this.style.background='rgba(255,215,0,0.1)'; this.style.borderColor='#ffd700'; this.style.color='#ffd700'" onmouseout="this.style.background='rgba(255,255,255,0.03)'; this.style.borderColor='rgba(255,255,255,0.15)'; this.style.color='var(--color-text-muted)'" title="Pin as rival">pin rival</button>`;

        html += `
            <tr id="${rowId}" style="background: ${rowGradient}; border-bottom: 1px solid rgba(255,255,255,0.05); transition: all 0.2s;" onmouseover="this.style.background='${rowHoverGradient}'" onmouseout="this.style.background='${rowGradient}'">
                <td style="padding: 0.6rem 1rem; text-align: center; color: ${rankColor}; font-weight: 700; font-size: 1.1rem;">${rankIcon} ${index + 1}${rankChangeIndicator}</td>
                <td style="padding: 0.6rem 1rem; color: var(--color-primary); font-weight: 700; font-size: 1rem;">
                    <div style="display: flex; align-items: center; gap: 0.4rem; flex-wrap: wrap;">
                        <span onclick="showDRGraph('${player.user_guid}', '${player.psn_id}')" style="cursor: pointer;" title="Click to view DR history">${countryFlag}${player.psn_id}${specialEmoji}</span>
                        ${rivalButton}
                        <button onclick='event.stopPropagation(); showNoteEditor(${JSON.stringify(player).replace(/'/g, "\\'")} )' style="background: rgba(255,255,255,0.03); border: 1px solid rgba(255,255,255,0.15); color: var(--color-text-muted); padding: 0.15rem 0.5rem; border-radius: 12px; cursor: pointer; font-size: 0.65rem; transition: all 0.2s; text-transform: uppercase; letter-spacing: 0.5px; font-weight: 600;" onmouseover="this.style.background='rgba(0,255,136,0.1)'; this.style.borderColor='var(--color-primary)'; this.style.color='var(--color-primary)'" onmouseout="this.style.background='rgba(255,255,255,0.03)'; this.style.borderColor='rgba(255,255,255,0.15)'; this.style.color='var(--color-text-muted)'" title="Add personal note">add note</button>
                        ${tagsHTML}
                    </div>
                </td>
                <td style="padding: 0.6rem 1rem; text-align: center; color: var(--text-color); font-weight: 600;">${player.dr?.toLocaleString() || 0}${trendArrow}</td>
                <td id="${trendCellId}" style="padding: 0.6rem 1rem; text-align: center;">
                    <div style="display: flex; align-items: center; justify-content: center; min-height: 30px;">
                        <div style="color: var(--color-text-muted); font-size: 0.75rem;">...</div>
                    </div>
                </td>
                <td style="padding: 0.6rem 1rem; text-align: center; color: var(--color-primary); font-weight: 800; font-size: 1.2rem;">${player.rank || 'E'}</td>
                <td style="padding: 0.6rem 1rem; text-align: center; color: var(--color-secondary); font-weight: 800; font-size: 1.1rem;">${player.sr_grade || 'E'}</td>
                <td style="padding: 0.6rem 1rem; text-align: center; color: var(--text-color);">${player.total_races?.toLocaleString() || 0}</td>
                <td style="padding: 0.6rem 1rem; text-align: center; color: var(--color-primary); font-weight: 600;">${player.win_percentage?.toFixed(1) || 0}%</td>
                <td style="padding: 0.6rem 1rem; text-align: center; color: var(--color-secondary); font-weight: 600;">${player.pole_percentage?.toFixed(1) || 0}%</td>
                <td style="padding: 0.6rem 1rem; text-align: center; color: var(--color-primary); font-weight: 600;">${player.fastest_lap_percentage?.toFixed(1) || 0}%</td>
                <td style="padding: 0.6rem 1rem; text-align: center;">
                    <button onclick='showSimilarDrivers(${JSON.stringify(player).replace(/'/g, "\\'")} )' style="background: linear-gradient(135deg, rgba(0,255,136,0.1), rgba(14,165,233,0.1)); border: 1px solid rgba(0,255,136,0.3); color: var(--color-primary); padding: 0.4rem 0.8rem; border-radius: 6px; cursor: pointer; font-size: 0.75rem; font-weight: 600; transition: all 0.2s;" onmouseover="this.style.background='linear-gradient(135deg, rgba(0,255,136,0.2), rgba(14,165,233,0.2))'" onmouseout="this.style.background='linear-gradient(135deg, rgba(0,255,136,0.1), rgba(14,165,233,0.1))'">Find</button>
                </td>
            </tr>
        `;

        // Fetch and display sparkline asynchronously
        fetchDRHistory(player.user_guid, player.psn_id).then(historyData => {
            const cell = document.getElementById(trendCellId);
            if (cell && historyData) {
                cell.innerHTML = `<div style="display: flex; align-items: center; justify-content: center;">${createSparkline(historyData, 80, 30)}</div>`;
            }
        });
    });

    html += `
                </tbody>
            </table>
        </div>

        <!-- Mobile Card View -->
        <div class="mobile-leaderboard">
    `;

    pageData.forEach((player, pageIndex) => {
        const index = startIndex + pageIndex; // Global index for ranking
        const rankColor = index === 0 ? '#ffd700' : index === 1 ? '#c0c0c0' : index === 2 ? '#cd7f32' : 'var(--color-text-muted)';
        const rankIcon = index === 0 ? '🥇' : index === 1 ? '🥈' : index === 2 ? '🥉' : '';

        // DR Trend Arrow for mobile
        let trendArrowMobile = '';
        if (player.dr_change !== undefined && player.dr_change !== null && player.dr_change !== 0) {
            const changeColor = player.dr_change > 0 ? '#00ff88' : '#ff4444';
            const arrowIcon = player.dr_change > 0 ? '↑' : '↓';
            const changeSign = player.dr_change > 0 ? '+' : '';
            trendArrowMobile = `<div style="color: ${changeColor}; font-size: 0.75rem; margin-top: 0.25rem;">${arrowIcon} ${changeSign}${player.dr_change}</div>`;
        }

        // Country Flag for mobile
        const countryFlagMobile = player.country_code ? getCountryFlag(player.country_code) + ' ' : '';

        // Special emoji for specific players (mobile)
        const specialEmojiMobile = player.psn_id === 'marris_GT7' ? ' 🎂' : '';

        // Rival tracking for mobile
        const playerIsRivalMobile = isRival(player.user_guid);
        const cardBg = playerIsRivalMobile ? 'linear-gradient(135deg, rgba(255,215,0,0.1), rgba(255,165,0,0.05))' : 'rgba(255,255,255,0.03)';
        const cardBorder = playerIsRivalMobile ? '2px solid rgba(255,215,0,0.5)' : '1px solid rgba(255,255,255,0.1)';

        // Rival button for mobile
        const rivalButtonMobile = playerIsRivalMobile
            ? `<button onclick='event.stopPropagation(); removeRival("${player.user_guid}")' style="background: rgba(255,215,0,0.1); border: 1px solid rgba(255,215,0,0.4); color: #ffd700; padding: 0.4rem 0.75rem; border-radius: 8px; cursor: pointer; font-size: 0.7rem; font-weight: 600;">⭐ Rival</button>`
            : `<button onclick='event.stopPropagation(); addRival(${JSON.stringify(player).replace(/'/g, "\\'")} )' style="background: rgba(255,255,255,0.05); border: 1px solid rgba(255,255,255,0.15); color: var(--color-text-muted); padding: 0.4rem 0.75rem; border-radius: 8px; cursor: pointer; font-size: 0.7rem; font-weight: 600;">Pin Rival</button>`;

        html += `
            <div style="background: ${cardBg}; border: ${cardBorder}; border-radius: 12px; padding: 1.5rem; margin-bottom: 1rem;">
                <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 1rem; padding-bottom: 1rem; border-bottom: 1px solid rgba(255,255,255,0.1);">
                    <div>
                        <div style="color: ${rankColor}; font-weight: 700; font-size: 1.1rem; margin-bottom: 0.25rem;">${rankIcon} #${index + 1}</div>
                        <div style="color: var(--color-primary); font-weight: 700; font-size: 1.3rem; cursor: pointer;" onclick="showDRGraph('${player.user_guid}', '${player.psn_id}')" title="Click to view DR history">${countryFlagMobile}${player.psn_id}${specialEmojiMobile}</div>
                    </div>
                    <div style="text-align: right;">
                        <div style="color: var(--color-primary); font-weight: 800; font-size: 2rem; line-height: 1;">${player.rank || 'E'}</div>
                        <div style="color: var(--text-color); font-size: 0.9rem;">${player.dr?.toLocaleString() || 0} DR</div>
                        ${trendArrowMobile}
                    </div>
                </div>
                <div style="display: flex; gap: 0.5rem; margin-bottom: 1rem; flex-wrap: wrap;">
                    ${rivalButtonMobile}
                    <button onclick='event.stopPropagation(); showNoteEditor(${JSON.stringify(player).replace(/'/g, "\\'")} )' style="background: rgba(255,255,255,0.05); border: 1px solid rgba(255,255,255,0.15); color: var(--color-text-muted); padding: 0.4rem 0.75rem; border-radius: 8px; cursor: pointer; font-size: 0.7rem; font-weight: 600;">Add Note</button>
                </div>
                <div style="display: grid; grid-template-columns: repeat(2, 1fr); gap: 0.75rem;">
                    <div style="text-align: center; padding: 0.75rem; background: rgba(255,255,255,0.03); border-radius: 8px;">
                        <div style="color: var(--color-secondary); font-weight: 800; font-size: 1.5rem;">${player.sr_grade || 'E'}</div>
                        <div style="color: var(--color-text-muted); font-size: 0.7rem; text-transform: uppercase;">SR</div>
                    </div>
                    <div style="text-align: center; padding: 0.75rem; background: rgba(255,255,255,0.03); border-radius: 8px;">
                        <div style="color: var(--text-color); font-weight: 700; font-size: 1.2rem;">${player.total_races?.toLocaleString() || 0}</div>
                        <div style="color: var(--color-text-muted); font-size: 0.7rem; text-transform: uppercase;">Races</div>
                    </div>
                    <div style="text-align: center; padding: 0.75rem; background: rgba(255,255,255,0.03); border-radius: 8px;">
                        <div style="color: var(--color-primary); font-weight: 700; font-size: 1.2rem;">${player.win_percentage?.toFixed(1) || 0}%</div>
                        <div style="color: var(--color-text-muted); font-size: 0.7rem; text-transform: uppercase;">Win Rate</div>
                    </div>
                    <div style="text-align: center; padding: 0.75rem; background: rgba(255,255,255,0.03); border-radius: 8px;">
                        <div style="color: var(--color-secondary); font-weight: 700; font-size: 1.2rem;">${player.pole_percentage?.toFixed(1) || 0}%</div>
                        <div style="color: var(--color-text-muted); font-size: 0.7rem; text-transform: uppercase;">Pole Rate</div>
                    </div>
                </div>
            </div>
        `;
    });

    html += `
        </div>

        <!-- Pagination Controls -->
        <div style="margin-top: 2rem; display: flex; justify-content: center; align-items: center; gap: 1.5rem;">
            <button
                onclick="changePage('prev')"
                class="btn btn-secondary"
                style="padding: 0.75rem 1.5rem; ${currentPage === 1 ? 'opacity: 0.5; cursor: not-allowed;' : ''}"
                ${currentPage === 1 ? 'disabled' : ''}
            >
                ← Previous
            </button>

            <div style="color: var(--color-text-muted); font-size: 1rem; font-weight: 600;">
                Page ${currentPage} of ${totalPages}
            </div>

            <button
                onclick="changePage('next')"
                class="btn btn-secondary"
                style="padding: 0.75rem 1.5rem; ${currentPage === totalPages ? 'opacity: 0.5; cursor: not-allowed;' : ''}"
                ${currentPage === totalPages ? 'disabled' : ''}
            >
                Next →
            </button>
        </div>

        <style>
            @media (min-width: 768px) {
                .desktop-leaderboard { display: block !important; }
                .mobile-leaderboard { display: none !important; }
            }
        </style>
    `;

    leaderboardResults.innerHTML = html;

    // Save current positions for rank change tracking
    saveLeaderboardPositions(leaderboardData);
}

// ===== CHAMPION RANKINGS =====
let currentView = 'leaderboard'; // Track current view

function switchView(view) {
    currentView = view;
    const leaderboardTab = document.getElementById('leaderboardTab');
    const championTab = document.getElementById('championTab');
    const leaderboardResults = document.getElementById('leaderboardResults');
    const championResults = document.getElementById('championResults');

    if (view === 'leaderboard') {
        // Update tab styles
        leaderboardTab.style.background = 'linear-gradient(135deg, var(--color-primary), #00cc6a)';
        leaderboardTab.style.border = 'none';
        championTab.style.background = '';
        championTab.className = 'btn btn-secondary';

        // Show/hide sections
        leaderboardResults.style.display = 'block';
        championResults.style.display = 'none';
    } else {
        // Update tab styles
        championTab.style.background = 'linear-gradient(135deg, var(--color-primary), #00cc6a)';
        championTab.style.border = 'none';
        leaderboardTab.style.background = '';
        leaderboardTab.className = 'btn btn-secondary';

        // Show/hide sections
        leaderboardResults.style.display = 'none';
        championResults.style.display = 'block';

        // Display champion rankings
        displayChampionRankings();
    }
}

function displayChampionRankings() {
    const championResults = document.getElementById('championResults');

    if (!leaderboardData || leaderboardData.length === 0) {
        championResults.innerHTML = `
            <div style="background: rgba(255,255,255,0.05); border: 1px solid rgba(255,255,255,0.1); border-radius: 12px; padding: 3rem; text-align: center;">
                <p style="color: var(--color-text-muted); font-size: 1.2rem; margin-bottom: 1rem;">No champions yet</p>
                <p style="color: var(--color-text-muted);">Be the first to qualify!</p>
            </div>
        `;
        return;
    }

    // Calculate champion scores for all players
    const championsData = leaderboardData
        .map(player => {
            const score = calculateChampionScore(player);
            if (!score) return null;
            return { ...player, championScore: score };
        })
        .filter(p => p !== null)
        .sort((a, b) => b.championScore.total - a.championScore.total);

    if (championsData.length === 0) {
        championResults.innerHTML = `
            <div style="background: rgba(255,255,255,0.05); border: 1px solid rgba(255,255,255,0.1); border-radius: 12px; padding: 3rem; text-align: center;">
                <p style="color: var(--color-text-muted); font-size: 1.2rem; margin-bottom: 1rem;">No qualified champions yet</p>
                <p style="color: var(--color-text-muted);">Players need at least 10 races to qualify for Champion Rankings</p>
            </div>
        `;
        return;
    }

    // Top 3 Champion Podium
    let podiumHtml = '';
    if (championsData.length >= 3) {
        const top3 = championsData.slice(0, 3);

        const flag1 = top3[0].country_code ? getCountryFlag(top3[0].country_code) + ' ' : '';
        const flag2 = top3[1].country_code ? getCountryFlag(top3[1].country_code) + ' ' : '';
        const flag3 = top3[2].country_code ? getCountryFlag(top3[2].country_code) + ' ' : '';

        const tier1 = getChampionTier(top3[0].championScore.total);
        const tier2 = getChampionTier(top3[1].championScore.total);
        const tier3 = getChampionTier(top3[2].championScore.total);

        podiumHtml = `
            <div style="margin-bottom: 3rem;">
                <h3 style="text-align: center; color: var(--color-primary); font-size: 1.5rem; margin-bottom: 2rem; text-transform: uppercase; letter-spacing: 2px;">
                    👑 Top 3 Overall Champions 👑
                </h3>
                <div style="display: flex; justify-content: center; align-items: flex-end; gap: 2rem; flex-wrap: wrap; max-width: 900px; margin: 0 auto;">
                    <!-- 2nd Place -->
                    <div style="flex: 1; min-width: 200px; max-width: 250px; background: linear-gradient(135deg, rgba(192,192,192,0.2), rgba(192,192,192,0.05)); border: 2px solid #c0c0c0; border-radius: 16px; padding: 2rem 1.5rem; text-align: center; transform: translateY(20px);">
                        <div style="font-size: 3rem; margin-bottom: 0.5rem;">🥈</div>
                        <div style="color: #c0c0c0; font-weight: 900; font-size: 2rem; margin-bottom: 0.5rem;">#2</div>
                        <div style="color: var(--color-primary); font-weight: 700; font-size: 1.3rem; margin-bottom: 1rem;">${flag2}${top3[1].psn_id}</div>
                        <div style="background: rgba(255,255,255,0.05); border-radius: 8px; padding: 1rem; margin-bottom: 0.5rem;">
                            <div style="color: ${tier2.color}; font-size: 2rem; margin-bottom: 0.5rem;">${tier2.icon}</div>
                            <div style="color: ${tier2.color}; font-weight: 700; font-size: 1.1rem; margin-bottom: 0.5rem;">${tier2.name}</div>
                            <div style="color: var(--color-primary); font-weight: 800; font-size: 2.5rem;">${top3[1].championScore.total.toFixed(1)}</div>
                            <div style="color: var(--color-text-muted); font-size: 0.9rem;">Champion Score</div>
                        </div>
                    </div>

                    <!-- 1st Place (Champion) -->
                    <div style="flex: 1; min-width: 200px; max-width: 270px; background: linear-gradient(135deg, rgba(255,215,0,0.3), rgba(255,215,0,0.05)); border: 3px solid #ffd700; border-radius: 16px; padding: 2.5rem 1.5rem; text-align: center; box-shadow: 0 8px 32px rgba(255,215,0,0.3);">
                        <div style="font-size: 4rem; margin-bottom: 0.5rem;">🥇</div>
                        <div style="color: #ffd700; font-weight: 900; font-size: 2.5rem; margin-bottom: 0.5rem; text-shadow: 0 0 20px rgba(255,215,0,0.5);">#1</div>
                        <div style="color: var(--color-primary); font-weight: 900; font-size: 1.5rem; margin-bottom: 1rem;">${flag1}${top3[0].psn_id}</div>
                        <div style="background: rgba(255,255,255,0.1); border-radius: 8px; padding: 1.25rem; margin-bottom: 0.5rem;">
                            <div style="color: ${tier1.color}; font-size: 2.5rem; margin-bottom: 0.5rem;">${tier1.icon}</div>
                            <div style="color: ${tier1.color}; font-weight: 700; font-size: 1.2rem; margin-bottom: 0.5rem;">${tier1.name}</div>
                            <div style="color: var(--color-primary); font-weight: 800; font-size: 3rem;">${top3[0].championScore.total.toFixed(1)}</div>
                            <div style="color: var(--color-text-muted); font-size: 0.9rem;">Champion Score</div>
                        </div>
                    </div>

                    <!-- 3rd Place -->
                    <div style="flex: 1; min-width: 200px; max-width: 250px; background: linear-gradient(135deg, rgba(205,127,50,0.2), rgba(205,127,50,0.05)); border: 2px solid #cd7f32; border-radius: 16px; padding: 2rem 1.5rem; text-align: center; transform: translateY(20px);">
                        <div style="font-size: 3rem; margin-bottom: 0.5rem;">🥉</div>
                        <div style="color: #cd7f32; font-weight: 900; font-size: 2rem; margin-bottom: 0.5rem;">#3</div>
                        <div style="color: var(--color-primary); font-weight: 700; font-size: 1.3rem; margin-bottom: 1rem;">${flag3}${top3[2].psn_id}</div>
                        <div style="background: rgba(255,255,255,0.05); border-radius: 8px; padding: 1rem; margin-bottom: 0.5rem;">
                            <div style="color: ${tier3.color}; font-size: 2rem; margin-bottom: 0.5rem;">${tier3.icon}</div>
                            <div style="color: ${tier3.color}; font-weight: 700; font-size: 1.1rem; margin-bottom: 0.5rem;">${tier3.name}</div>
                            <div style="color: var(--color-primary); font-weight: 800; font-size: 2.5rem;">${top3[2].championScore.total.toFixed(1)}</div>
                            <div style="color: var(--color-text-muted); font-size: 0.9rem;">Champion Score</div>
                        </div>
                    </div>
                </div>
            </div>
        `;
    }

    let html = podiumHtml + `
        <div style="margin-bottom: 1.5rem; text-align: center;">
            <p style="color: var(--color-text-muted); font-size: 1rem;">
                ${championsData.length} qualified champion${championsData.length !== 1 ? 's' : ''}
            </p>
            <p style="color: var(--color-text-muted); font-size: 0.85rem; margin-top: 0.5rem;">
                Champion Score: DR(40%) + Win%(25%) + SR(15%) + Pole%(10%) + FL%(10%)
            </p>
        </div>

        <!-- Desktop Table View -->
        <div style="display: none; overflow-x: auto; background: rgba(255,255,255,0.03); border-radius: 12px; border: 1px solid rgba(255,255,255,0.1);" class="desktop-leaderboard">
            <table style="width: 100%; border-collapse: collapse;">
                <thead>
                    <tr style="background: rgba(0,255,136,0.1); border-bottom: 2px solid rgba(0,255,136,0.3);">
                        <th style="padding: 1rem; text-align: center; color: var(--color-primary); font-size: 0.75rem; text-transform: uppercase; letter-spacing: 1px;">#</th>
                        <th style="padding: 1rem; text-align: left; color: var(--color-primary); font-size: 0.75rem; text-transform: uppercase; letter-spacing: 1px;">PSN ID</th>
                        <th style="padding: 1rem; text-align: center; color: var(--color-primary); font-size: 0.75rem; text-transform: uppercase; letter-spacing: 1px;">Tier</th>
                        <th style="padding: 1rem; text-align: center; color: var(--color-primary); font-size: 0.75rem; text-transform: uppercase; letter-spacing: 1px;">Score</th>
                        <th style="padding: 1rem; text-align: center; color: var(--color-primary); font-size: 0.75rem; text-transform: uppercase; letter-spacing: 1px;">DR</th>
                        <th style="padding: 1rem; text-align: center; color: var(--color-primary); font-size: 0.75rem; text-transform: uppercase; letter-spacing: 1px;">Win%</th>
                        <th style="padding: 1rem; text-align: center; color: var(--color-primary); font-size: 0.75rem; text-transform: uppercase; letter-spacing: 1px;">SR</th>
                        <th style="padding: 1rem; text-align: center; color: var(--color-primary); font-size: 0.75rem; text-transform: uppercase; letter-spacing: 1px;">Races</th>
                    </tr>
                </thead>
                <tbody>
    `;

    championsData.forEach((player, index) => {
        const tier = getChampionTier(player.championScore.total);
        const countryFlag = player.country_code ? getCountryFlag(player.country_code) + ' ' : '';
        const breakdown = player.championScore.breakdown;

        html += `
                    <tr style="border-bottom: 1px solid rgba(255,255,255,0.05); transition: background 0.3s ease;" onmouseover="this.style.background='rgba(0,255,136,0.05)'" onmouseout="this.style.background='transparent'">
                        <td style="padding: 1rem; text-align: center; color: var(--color-text-muted); font-weight: 700;">${index + 1}</td>
                        <td style="padding: 1rem; color: var(--color-primary); font-weight: 700; font-size: 1rem; cursor: pointer;" onclick="showDRGraph('${player.user_guid}', '${player.psn_id}')" title="Click to view DR history">${countryFlag}${player.psn_id}</td>
                        <td style="padding: 1rem; text-align: center;">
                            <div style="color: ${tier.color}; font-size: 1.5rem;">${tier.icon}</div>
                            <div style="color: ${tier.color}; font-size: 0.85rem; font-weight: 600;">${tier.name}</div>
                        </td>
                        <td style="padding: 1rem; text-align: center;" title="DR: ${breakdown.dr.toFixed(1)} | Win: ${breakdown.winRate.toFixed(1)} | SR: ${breakdown.sr.toFixed(1)} | Pole: ${breakdown.poleRate.toFixed(1)} | FL: ${breakdown.flRate.toFixed(1)}">
                            <div style="color: var(--color-primary); font-weight: 800; font-size: 1.5rem;">${player.championScore.total.toFixed(1)}</div>
                            <div style="color: var(--color-text-muted); font-size: 0.75rem;">hover for breakdown</div>
                        </td>
                        <td style="padding: 1rem; text-align: center; color: var(--text-color);">${player.dr?.toLocaleString() || 0}</td>
                        <td style="padding: 1rem; text-align: center; color: var(--text-color);">${player.win_percentage?.toFixed(1) || 0}%</td>
                        <td style="padding: 1rem; text-align: center; color: var(--text-color);">${player.sr || 0}</td>
                        <td style="padding: 1rem; text-align: center; color: var(--text-color);">${player.total_races?.toLocaleString() || 0}</td>
                    </tr>
        `;
    });

    html += `
                </tbody>
            </table>
        </div>

        <!-- Mobile Card View -->
        <div style="display: none;" class="mobile-leaderboard">
    `;

    championsData.forEach((player, index) => {
        const tier = getChampionTier(player.championScore.total);
        const countryFlagMobile = player.country_code ? getCountryFlag(player.country_code) + ' ' : '';
        const breakdown = player.championScore.breakdown;

        html += `
            <div style="background: rgba(255,255,255,0.03); border: 1px solid rgba(255,255,255,0.1); border-radius: 12px; padding: 1.5rem; margin-bottom: 1rem;">
                <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 1rem; padding-bottom: 1rem; border-bottom: 1px solid rgba(255,255,255,0.1);">
                    <div>
                        <div style="color: var(--color-text-muted); font-weight: 700; font-size: 1.1rem; margin-bottom: 0.25rem;">#${index + 1}</div>
                        <div style="color: var(--color-primary); font-weight: 700; font-size: 1.3rem; cursor: pointer;" onclick="showDRGraph('${player.user_guid}', '${player.psn_id}')" title="Click to view DR history">${countryFlagMobile}${player.psn_id}</div>
                    </div>
                    <div style="text-align: right;">
                        <div style="color: ${tier.color}; font-size: 2rem;">${tier.icon}</div>
                        <div style="color: ${tier.color}; font-size: 0.9rem; font-weight: 600;">${tier.name}</div>
                    </div>
                </div>
                <div style="text-align: center; margin-bottom: 1rem; padding: 1rem; background: rgba(255,255,255,0.05); border-radius: 8px;">
                    <div style="color: var(--color-primary); font-weight: 800; font-size: 2.5rem; margin-bottom: 0.25rem;">${player.championScore.total.toFixed(1)}</div>
                    <div style="color: var(--color-text-muted); font-size: 0.9rem;">Champion Score</div>
                </div>
                <div style="display: grid; grid-template-columns: repeat(2, 1fr); gap: 0.75rem; font-size: 0.9rem;">
                    <div>
                        <span style="color: var(--color-text-muted);">DR:</span>
                        <span style="color: var(--text-color); margin-left: 0.25rem; font-weight: 600;">${breakdown.dr.toFixed(1)}</span>
                    </div>
                    <div>
                        <span style="color: var(--color-text-muted);">Win%:</span>
                        <span style="color: var(--text-color); margin-left: 0.25rem; font-weight: 600;">${breakdown.winRate.toFixed(1)}</span>
                    </div>
                    <div>
                        <span style="color: var(--color-text-muted);">SR:</span>
                        <span style="color: var(--text-color); margin-left: 0.25rem; font-weight: 600;">${breakdown.sr.toFixed(1)}</span>
                    </div>
                    <div>
                        <span style="color: var(--color-text-muted);">Pole%:</span>
                        <span style="color: var(--text-color); margin-left: 0.25rem; font-weight: 600;">${breakdown.poleRate.toFixed(1)}</span>
                    </div>
                    <div style="grid-column: 1 / -1;">
                        <span style="color: var(--color-text-muted);">FL%:</span>
                        <span style="color: var(--text-color); margin-left: 0.25rem; font-weight: 600;">${breakdown.flRate.toFixed(1)}</span>
                    </div>
                </div>
            </div>
        `;
    });

    html += `
        </div>
    `;

    championResults.innerHTML = html;
}

// Load leaderboard when page loads
document.addEventListener('DOMContentLoaded', () => {
    fetchLeaderboard();

    // Auto-refresh leaderboard every 1 hour
    setInterval(() => {
        console.log('Auto-refreshing leaderboard...');
        fetchLeaderboard(currentSort);
    }, 3600000); // 1 hour = 3,600,000 milliseconds
});

// ===== DR HISTORY GRAPH =====
let drChartInstance = null;

async function showDRGraph(userGuid, psnId) {
    const modal = document.getElementById('drGraphModal');
    const playerName = document.getElementById('graphPlayerName');
    const canvas = document.getElementById('drChart');

    playerName.textContent = `${psnId} - DR History (Last 7 Days)`;
    modal.style.display = 'flex';

    try {
        // Fetch player history
        const response = await fetch(`/.netlify/functions/player-history?userGuid=${encodeURIComponent(userGuid)}&days=7`);
        const data = await response.json();

        if (!data.success || data.history.length === 0) {
            canvas.parentElement.innerHTML += '<p style="color: var(--color-text-muted); text-align: center; margin-top: 2rem;">No history data available yet. Check back after the hourly update!</p>';
            return;
        }

        // Group data by day (aggregate hourly data into daily points)
        const dailyData = {};
        data.history.forEach(h => {
            const date = new Date(h.recorded_at);
            const dayKey = date.toLocaleDateString('en-US', { month: 'short', day: 'numeric', year: 'numeric' });

            // Keep the latest entry for each day
            if (!dailyData[dayKey] || new Date(h.recorded_at) > new Date(dailyData[dayKey].recorded_at)) {
                dailyData[dayKey] = h;
            }
        });

        // Convert to arrays sorted by date
        const sortedDays = Object.keys(dailyData).sort((a, b) =>
            new Date(dailyData[a].recorded_at) - new Date(dailyData[b].recorded_at)
        );

        const labels = sortedDays;
        const drData = sortedDays.map(day => dailyData[day].dr);

        // Destroy existing chart if it exists
        if (drChartInstance) {
            drChartInstance.destroy();
        }

        // Create chart
        drChartInstance = new Chart(canvas, {
            type: 'line',
            data: {
                labels: labels,
                datasets: [{
                    label: 'Driver Rating',
                    data: drData,
                    borderColor: '#00ff88',
                    backgroundColor: 'rgba(0, 255, 136, 0.1)',
                    borderWidth: 3,
                    fill: true,
                    tension: 0.4,
                    pointBackgroundColor: '#00ff88',
                    pointBorderColor: '#fff',
                    pointBorderWidth: 2,
                    pointRadius: 5,
                    pointHoverRadius: 7,
                }]
            },
            options: {
                responsive: true,
                maintainAspectRatio: true,
                plugins: {
                    legend: {
                        display: false
                    },
                    tooltip: {
                        backgroundColor: 'rgba(10, 14, 18, 0.9)',
                        titleColor: '#00ff88',
                        bodyColor: '#fff',
                        borderColor: '#00ff88',
                        borderWidth: 1,
                        padding: 12,
                        displayColors: false,
                        callbacks: {
                            title: (items) => items[0].label,
                            label: (item) => `DR: ${item.parsed.y.toLocaleString()}`
                        }
                    }
                },
                scales: {
                    y: {
                        beginAtZero: false,
                        grid: {
                            color: 'rgba(255, 255, 255, 0.1)'
                        },
                        ticks: {
                            color: '#94a3b8',
                            callback: (value) => value.toLocaleString()
                        }
                    },
                    x: {
                        grid: {
                            color: 'rgba(255, 255, 255, 0.05)'
                        },
                        ticks: {
                            color: '#94a3b8',
                            maxRotation: 45,
                            minRotation: 45
                        }
                    }
                }
            }
        });

    } catch (error) {
        console.error('Error fetching DR history:', error);
        canvas.parentElement.innerHTML += '<p style="color: #fca5a5; text-align: center; margin-top: 2rem;">Error loading history data</p>';
    }
}

// Close modal handlers
document.addEventListener('DOMContentLoaded', () => {
    const closeBtn = document.getElementById('closeGraphModal');
    const modal = document.getElementById('drGraphModal');

    if (closeBtn) {
        closeBtn.addEventListener('click', () => {
            modal.style.display = 'none';
        });
    }

    if (modal) {
        modal.addEventListener('click', (e) => {
            if (e.target.id === 'drGraphModal') {
                modal.style.display = 'none';
            }
        });
    }
});

// ===== CONSOLE WELCOME MESSAGE =====
console.log('%cSPARKSTHEORY', 'color: #0ea5e9; font-size: 48px; font-weight: bold; font-family: Rajdhani, sans-serif;');
console.log('%c🏎️ Welcome to the sparkstheory racing website!', 'color: #38bdf8; font-size: 16px;');
console.log('%cFeaturing live GT7 stats and premium 3D visuals!', 'color: #94a3b8; font-size: 12px;');
