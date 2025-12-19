// Scene setup
const scene = new THREE.Scene();
scene.fog = new THREE.FogExp2(0x000000, 0.002);

// Camera setup
const camera = new THREE.PerspectiveCamera(
    75,
    window.innerWidth / window.innerHeight,
    0.1,
    1000
);
camera.position.z = 5;

// Renderer setup
const renderer = new THREE.WebGLRenderer({ antialias: true, alpha: true });
renderer.setSize(window.innerWidth, window.innerHeight);
renderer.setPixelRatio(window.devicePixelRatio);
document.getElementById('canvas-container').appendChild(renderer.domElement);

// Lighting
const ambientLight = new THREE.AmbientLight(0xffffff, 0.5);
scene.add(ambientLight);

const pointLight1 = new THREE.PointLight(0x00ff88, 1, 100);
pointLight1.position.set(5, 5, 5);
scene.add(pointLight1);

const pointLight2 = new THREE.PointLight(0x00aaff, 1, 100);
pointLight2.position.set(-5, -5, 5);
scene.add(pointLight2);

// Create main 3D object
let currentShape = 'torus';
let geometry = new THREE.TorusGeometry(1, 0.4, 16, 100);
let material = new THREE.MeshStandardMaterial({
    color: 0x00ff88,
    metalness: 0.7,
    roughness: 0.2,
    wireframe: false
});
let mainMesh = new THREE.Mesh(geometry, material);
scene.add(mainMesh);

// Create particle system
const particlesGeometry = new THREE.BufferGeometry();
const particlesCount = 1000;
const posArray = new Float32Array(particlesCount * 3);

for (let i = 0; i < particlesCount * 3; i++) {
    posArray[i] = (Math.random() - 0.5) * 20;
}

particlesGeometry.setAttribute('position', new THREE.BufferAttribute(posArray, 3));
const particlesMaterial = new THREE.PointsMaterial({
    size: 0.02,
    color: 0x00aaff,
    transparent: true,
    opacity: 0.8
});
const particlesMesh = new THREE.Points(particlesGeometry, particlesMaterial);
scene.add(particlesMesh);

// Mouse interaction
let mouseX = 0;
let mouseY = 0;

document.addEventListener('mousemove', (event) => {
    mouseX = (event.clientX / window.innerWidth) * 2 - 1;
    mouseY = -(event.clientY / window.innerHeight) * 2 + 1;
});

// Animation variables
let rotationSpeed = 0.01;
let fastRotation = false;

// Button controls
const colorBtn = document.getElementById('colorBtn');
const speedBtn = document.getElementById('speedBtn');
const shapeBtn = document.getElementById('shapeBtn');

const colors = [0x00ff88, 0xff0088, 0x00aaff, 0xffaa00, 0xaa00ff];
let colorIndex = 0;

colorBtn.addEventListener('click', () => {
    colorIndex = (colorIndex + 1) % colors.length;
    mainMesh.material.color.setHex(colors[colorIndex]);
});

speedBtn.addEventListener('click', () => {
    fastRotation = !fastRotation;
    rotationSpeed = fastRotation ? 0.05 : 0.01;
    speedBtn.textContent = fastRotation ? 'Slow Down' : 'Speed Up';
});

shapeBtn.addEventListener('click', () => {
    scene.remove(mainMesh);
    geometry.dispose();

    if (currentShape === 'torus') {
        geometry = new THREE.IcosahedronGeometry(1.5, 0);
        currentShape = 'icosahedron';
    } else if (currentShape === 'icosahedron') {
        geometry = new THREE.OctahedronGeometry(1.5, 0);
        currentShape = 'octahedron';
    } else if (currentShape === 'octahedron') {
        geometry = new THREE.TorusKnotGeometry(1, 0.3, 100, 16);
        currentShape = 'torusKnot';
    } else {
        geometry = new THREE.TorusGeometry(1, 0.4, 16, 100);
        currentShape = 'torus';
    }

    mainMesh = new THREE.Mesh(geometry, material);
    scene.add(mainMesh);
});

// Animation loop
function animate() {
    requestAnimationFrame(animate);

    // Rotate main mesh
    mainMesh.rotation.x += rotationSpeed;
    mainMesh.rotation.y += rotationSpeed;

    // Mouse interaction with main mesh
    mainMesh.rotation.x += mouseY * 0.01;
    mainMesh.rotation.y += mouseX * 0.01;

    // Rotate particles
    particlesMesh.rotation.y += 0.001;

    // Animate lights
    const time = Date.now() * 0.001;
    pointLight1.position.x = Math.sin(time * 0.7) * 5;
    pointLight1.position.z = Math.cos(time * 0.7) * 5;

    pointLight2.position.x = Math.sin(time * 0.5 + Math.PI) * 5;
    pointLight2.position.z = Math.cos(time * 0.5 + Math.PI) * 5;

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
