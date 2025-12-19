// ===== THREE.JS RACING HELMET BACKGROUND =====
const scene = new THREE.Scene();

// Camera setup
const camera = new THREE.PerspectiveCamera(
    45,
    window.innerWidth / window.innerHeight,
    0.1,
    1000
);
camera.position.z = 8;
camera.position.y = 0;

// Renderer setup
const renderer = new THREE.WebGLRenderer({
    antialias: true,
    alpha: true
});
renderer.setSize(window.innerWidth, window.innerHeight);
renderer.setPixelRatio(window.devicePixelRatio);
document.getElementById('canvas-container').appendChild(renderer.domElement);

// Lighting for the helmet
const ambientLight = new THREE.AmbientLight(0xffffff, 0.4);
scene.add(ambientLight);

// Key light (main light from top-right)
const keyLight = new THREE.DirectionalLight(0x00ff88, 1.2);
keyLight.position.set(5, 5, 5);
scene.add(keyLight);

// Fill light (softer light from left)
const fillLight = new THREE.DirectionalLight(0x0ea5e9, 0.6);
fillLight.position.set(-5, 0, 3);
scene.add(fillLight);

// Rim light (backlight for edge glow)
const rimLight = new THREE.PointLight(0x00ff88, 1.5, 100);
rimLight.position.set(0, 3, -5);
scene.add(rimLight);

// Accent light
const accentLight = new THREE.PointLight(0x0ea5e9, 0.8, 100);
accentLight.position.set(-3, -2, 2);
scene.add(accentLight);

// Create Racing Helmet
const helmetGroup = new THREE.Group();

// Main helmet dome
const helmetGeometry = new THREE.SphereGeometry(1.2, 64, 64, 0, Math.PI * 2, 0, Math.PI * 0.7);
const helmetMaterial = new THREE.MeshStandardMaterial({
    color: 0x1a1a1a,
    metalness: 0.9,
    roughness: 0.1,
    envMapIntensity: 1
});
const helmetMesh = new THREE.Mesh(helmetGeometry, helmetMaterial);
helmetGroup.add(helmetMesh);

// Visor (glossy transparent)
const visorGeometry = new THREE.SphereGeometry(1.21, 64, 64, 0, Math.PI * 2, Math.PI * 0.25, Math.PI * 0.3);
const visorMaterial = new THREE.MeshStandardMaterial({
    color: 0x00ff88,
    metalness: 1,
    roughness: 0.05,
    transparent: true,
    opacity: 0.6,
    side: THREE.DoubleSide
});
const visorMesh = new THREE.Mesh(visorGeometry, visorMaterial);
helmetGroup.add(visorMesh);

// Racing stripe 1
const stripeGeometry1 = new THREE.TorusGeometry(1.22, 0.05, 16, 100, Math.PI * 0.6);
const stripeMaterial1 = new THREE.MeshStandardMaterial({
    color: 0x00ff88,
    metalness: 0.8,
    roughness: 0.2,
    emissive: 0x00ff88,
    emissiveIntensity: 0.3
});
const stripe1 = new THREE.Mesh(stripeGeometry1, stripeMaterial1);
stripe1.rotation.x = Math.PI / 2;
stripe1.rotation.y = -Math.PI / 6;
helmetGroup.add(stripe1);

// Racing stripe 2
const stripe2 = stripe1.clone();
stripe2.rotation.y = Math.PI / 6;
const stripeMaterial2 = stripeMaterial1.clone();
stripeMaterial2.color.setHex(0x0ea5e9);
stripeMaterial2.emissive.setHex(0x0ea5e9);
stripe2.material = stripeMaterial2;
helmetGroup.add(stripe2);

// Chin guard/bottom rim
const chinGeometry = new THREE.TorusGeometry(1.0, 0.15, 16, 32, Math.PI * 2);
const chinMaterial = new THREE.MeshStandardMaterial({
    color: 0x1a1a1a,
    metalness: 0.9,
    roughness: 0.2
});
const chinGuard = new THREE.Mesh(chinGeometry, chinMaterial);
chinGuard.rotation.x = Math.PI / 2;
chinGuard.position.y = -0.8;
helmetGroup.add(chinGuard);

// Air vents (decorative details)
for (let i = 0; i < 3; i++) {
    const ventGeometry = new THREE.CylinderGeometry(0.08, 0.08, 0.3, 16);
    const ventMaterial = new THREE.MeshStandardMaterial({
        color: 0x00ff88,
        metalness: 0.7,
        roughness: 0.3,
        emissive: 0x00ff88,
        emissiveIntensity: 0.2
    });
    const vent = new THREE.Mesh(ventGeometry, ventMaterial);
    vent.position.set(-0.6 + i * 0.3, 0.9, 0.8);
    vent.rotation.x = Math.PI / 3;
    helmetGroup.add(vent);
}

// Position the helmet group
helmetGroup.rotation.y = 0.3;
helmetGroup.rotation.x = -0.1;
scene.add(helmetGroup);

// Subtle floating particles
const particlesGeometry = new THREE.BufferGeometry();
const particlesCount = 300;
const posArray = new Float32Array(particlesCount * 3);

for (let i = 0; i < particlesCount; i++) {
    posArray[i * 3] = (Math.random() - 0.5) * 20;
    posArray[i * 3 + 1] = (Math.random() - 0.5) * 20;
    posArray[i * 3 + 2] = (Math.random() - 0.5) * 20;
}

particlesGeometry.setAttribute('position', new THREE.BufferAttribute(posArray, 3));
const particlesMaterial = new THREE.PointsMaterial({
    size: 0.03,
    color: 0x00ff88,
    transparent: true,
    opacity: 0.3,
    blending: THREE.AdditiveBlending
});
const particlesMesh = new THREE.Points(particlesGeometry, particlesMaterial);
scene.add(particlesMesh);

// Mouse interaction
let mouseX = 0;
let mouseY = 0;
let targetRotationY = 0;
let targetRotationX = 0;

document.addEventListener('mousemove', (event) => {
    mouseX = (event.clientX / window.innerWidth) * 2 - 1;
    mouseY = -(event.clientY / window.innerHeight) * 2 + 1;
    targetRotationY = mouseX * 0.5;
    targetRotationX = mouseY * 0.3;
});

// Animation loop
function animate() {
    requestAnimationFrame(animate);

    // Smooth helmet rotation based on mouse
    helmetGroup.rotation.y += (targetRotationY - helmetGroup.rotation.y) * 0.05;
    helmetGroup.rotation.x += (targetRotationX - helmetGroup.rotation.x) * 0.05;

    // Subtle auto-rotation when mouse is idle
    helmetGroup.rotation.y += 0.001;

    // Slowly rotate particles
    particlesMesh.rotation.y += 0.0005;
    particlesMesh.rotation.x += 0.0003;

    // Animate accent lights subtly
    const time = Date.now() * 0.001;
    rimLight.intensity = 1.5 + Math.sin(time * 0.5) * 0.3;
    accentLight.intensity = 0.8 + Math.sin(time * 0.7) * 0.2;

    renderer.render(scene, camera);
}

// Handle window resize
window.addEventListener('resize', () => {
    camera.aspect = window.innerWidth / window.innerHeight;
    camera.updateProjectionMatrix();
    renderer.setSize(window.innerWidth, window.innerHeight);
});

// Start animation
animate();

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
navBurger?.addEventListener('click', () => {
    navLinks.classList.toggle('active');
});

// Smooth scroll for navigation links
document.querySelectorAll('a[href^="#"]').forEach(anchor => {
    anchor.addEventListener('click', function (e) {
        e.preventDefault();
        const target = document.querySelector(this.getAttribute('href'));
        if (target) {
            target.scrollIntoView({
                behavior: 'smooth',
                block: 'start'
            });
            // Close mobile menu if open
            navLinks.classList.remove('active');
        }
    });
});

// ===== YOUTUBE VIDEO INTEGRATION =====
const YOUTUBE_CHANNEL_ID = 'UCyour_channel_id_here'; // You'll need to get this
const YOUTUBE_API_KEY = 'your_api_key_here'; // You'll need to get this from Google Cloud Console

// For now, we'll show placeholder videos
// To get real videos, you'll need to:
// 1. Go to https://console.cloud.google.com/
// 2. Create a project and enable YouTube Data API v3
// 3. Get your API key
// 4. Get your channel ID from your YouTube channel URL

function loadYouTubeVideos() {
    const videosGrid = document.getElementById('videosGrid');

    // Placeholder videos - replace with actual API call
    const placeholderVideos = [
        {
            title: 'Epic GT7 Race at Spa | Close Finish!',
            thumbnail: 'https://via.placeholder.com/640x360/0a0e12/00ff88?text=Video+1',
            url: 'https://youtube.com/@SparksTheory'
        },
        {
            title: 'Setup Guide: Finding the Perfect Balance',
            thumbnail: 'https://via.placeholder.com/640x360/0a0e12/0ea5e9?text=Video+2',
            url: 'https://youtube.com/@SparksTheory'
        },
        {
            title: 'Overtaking Masterclass | Race Analysis',
            thumbnail: 'https://via.placeholder.com/640x360/0a0e12/00ff88?text=Video+3',
            url: 'https://youtube.com/@SparksTheory'
        }
    ];

    videosGrid.innerHTML = placeholderVideos.map(video => `
        <a href="${video.url}" target="_blank" class="video-card">
            <div class="video-thumbnail">
                <img src="${video.thumbnail}" alt="${video.title}">
            </div>
            <div class="video-info">
                <h3 class="video-title">${video.title}</h3>
                <p class="video-meta">SparksTheory • GT7</p>
            </div>
        </a>
    `).join('');

    /*
    // Uncomment and configure this when you have API credentials:

    fetch(`https://www.googleapis.com/youtube/v3/search?key=${YOUTUBE_API_KEY}&channelId=${YOUTUBE_CHANNEL_ID}&part=snippet,id&order=date&maxResults=6`)
        .then(response => response.json())
        .then(data => {
            if (data.items) {
                videosGrid.innerHTML = data.items.map(item => {
                    if (item.id.videoId) {
                        return `
                            <a href="https://youtube.com/watch?v=${item.id.videoId}" target="_blank" class="video-card">
                                <div class="video-thumbnail">
                                    <img src="${item.snippet.thumbnails.medium.url}" alt="${item.snippet.title}">
                                </div>
                                <div class="video-info">
                                    <h3 class="video-title">${item.snippet.title}</h3>
                                    <p class="video-meta">${new Date(item.snippet.publishedAt).toLocaleDateString()}</p>
                                </div>
                            </a>
                        `;
                    }
                    return '';
                }).join('');
            }
        })
        .catch(error => {
            console.error('Error loading videos:', error);
            videosGrid.innerHTML = '<p class="video-placeholder">Unable to load videos. Visit <a href="https://youtube.com/@SparksTheory" target="_blank">my YouTube channel</a> directly.</p>';
        });
    */
}

// Load videos when page loads
document.addEventListener('DOMContentLoaded', loadYouTubeVideos);

// ===== GT7 DRIVER RATING CHECKER =====
const checkDriverBtn = document.getElementById('checkDriver');
const driverInput = document.getElementById('driverInput');
const checkerResults = document.getElementById('checkerResults');

checkDriverBtn?.addEventListener('click', () => {
    const driverId = driverInput.value.trim();

    if (!driverId) {
        checkerResults.innerHTML = '<p style="color: var(--color-accent);">Please enter a PSN ID</p>';
        return;
    }

    checkerResults.innerHTML = '<p>Searching...</p>';

    // Note: Gran Turismo 7 doesn't have an official public API
    // This is a placeholder for future integration or manual stats
    setTimeout(() => {
        checkerResults.innerHTML = `
            <div style="text-align: left;">
                <h3 style="color: var(--color-primary); margin-bottom: 1.5rem;">Driver Profile</h3>
                <div style="display: grid; gap: 1rem;">
                    <div style="display: flex; justify-content: space-between; padding: 0.5rem 0; border-bottom: 1px solid rgba(255,255,255,0.1);">
                        <span style="color: var(--color-text-muted);">PSN ID:</span>
                        <span style="font-weight: 600;">${driverId}</span>
                    </div>
                    <div style="display: flex; justify-content: space-between; padding: 0.5rem 0; border-bottom: 1px solid rgba(255,255,255,0.1);">
                        <span style="color: var(--color-text-muted);">Driver Rating:</span>
                        <span style="font-weight: 600; color: var(--color-primary);">A</span>
                    </div>
                    <div style="display: flex; justify-content: space-between; padding: 0.5rem 0; border-bottom: 1px solid rgba(255,255,255,0.1);">
                        <span style="color: var(--color-text-muted);">Sportsmanship:</span>
                        <span style="font-weight: 600; color: var(--color-secondary);">S</span>
                    </div>
                    <div style="display: flex; justify-content: space-between; padding: 0.5rem 0;">
                        <span style="color: var(--color-text-muted);">Total Races:</span>
                        <span style="font-weight: 600;">142</span>
                    </div>
                </div>
                <p style="margin-top: 1.5rem; color: var(--color-text-muted); font-size: 0.85rem; font-style: italic;">
                    Note: GT7 stats are manually updated. For real-time stats, check your in-game profile.
                </p>
            </div>
        `;
    }, 1000);

    /*
    // Future: If GT7 API becomes available or using a third-party tracker:

    fetch(`https://api.example.com/gt7/driver/${driverId}`)
        .then(response => response.json())
        .then(data => {
            checkerResults.innerHTML = // ... render real data
        })
        .catch(error => {
            checkerResults.innerHTML = '<p style="color: var(--color-accent);">Driver not found or API unavailable</p>';
        });
    */
});

// ===== CONTACT FORM =====
const contactForm = document.getElementById('contactForm');

contactForm?.addEventListener('submit', (e) => {
    e.preventDefault();

    const formData = new FormData(contactForm);
    const submitBtn = contactForm.querySelector('button[type="submit"]');
    const originalText = submitBtn.textContent;

    submitBtn.textContent = 'Sending...';
    submitBtn.disabled = true;

    // Simulate form submission
    // Replace this with your actual form handling (e.g., FormSpree, Netlify Forms, or your backend)
    setTimeout(() => {
        submitBtn.textContent = 'Message Sent!';
        submitBtn.style.background = 'var(--color-secondary)';
        contactForm.reset();

        setTimeout(() => {
            submitBtn.textContent = originalText;
            submitBtn.disabled = false;
            submitBtn.style.background = '';
        }, 3000);
    }, 1500);

    /*
    // Example with FormSpree or similar service:

    fetch('https://formspree.io/f/your_form_id', {
        method: 'POST',
        body: formData,
        headers: {
            'Accept': 'application/json'
        }
    })
    .then(response => {
        if (response.ok) {
            submitBtn.textContent = 'Message Sent!';
            contactForm.reset();
        } else {
            submitBtn.textContent = 'Error - Try Again';
        }
    })
    .catch(error => {
        submitBtn.textContent = 'Error - Try Again';
    })
    .finally(() => {
        setTimeout(() => {
            submitBtn.textContent = originalText;
            submitBtn.disabled = false;
        }, 3000);
    });
    */
});

// ===== SCROLL ANIMATIONS =====
// Add fade-in animations for sections as they come into view
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

// Observe all sections
document.querySelectorAll('.section').forEach(section => {
    section.style.opacity = '0';
    section.style.transform = 'translateY(30px)';
    section.style.transition = 'opacity 0.8s ease, transform 0.8s ease';
    observer.observe(section);
});

// ===== CONSOLE WELCOME MESSAGE =====
console.log('%cSPARKSTHEORY', 'color: #00ff88; font-size: 48px; font-weight: bold; font-family: Rajdhani, sans-serif;');
console.log('%c🏎️ Welcome to the sparkstheory racing website!', 'color: #0ea5e9; font-size: 16px;');
console.log('%cBuilt with Three.js, love, and lots of virtual racing', 'color: #94a3b8; font-size: 12px;');
