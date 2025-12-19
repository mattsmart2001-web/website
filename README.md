# Three.js Interactive Website

An interactive 3D website built with Three.js featuring animated 3D shapes, particle effects, and mouse-driven interactions.

## Features

- **3D Animated Shapes**: Rotating geometric shapes with smooth animations
- **Multiple Geometries**: Switch between Torus, Icosahedron, Octahedron, and Torus Knot
- **Particle System**: Animated background particles for added depth
- **Mouse Interaction**: Move your mouse to interact with the 3D scene
- **Dynamic Lighting**: Animated point lights that move around the scene
- **Color Themes**: Cycle through different color schemes
- **Adjustable Speed**: Toggle between normal and fast rotation speeds
- **Responsive Design**: Works on desktop and mobile devices

## How to Use

1. **Open the website**: Simply open `index.html` in a modern web browser
2. **Interact with the scene**: Move your mouse around to affect the rotation
3. **Use the controls**:
   - **Change Color**: Cycles through different color themes
   - **Toggle Speed**: Switches between normal and fast rotation
   - **Change Shape**: Switches between different 3D geometries

## Technologies Used

- **Three.js**: 3D graphics library
- **HTML5**: Structure
- **CSS3**: Styling and animations
- **JavaScript**: Scene logic and interactions

## File Structure

```
website/
├── index.html      # Main HTML file
├── style.css       # Styling and layout
├── script.js       # Three.js scene and logic
└── README.md       # Documentation
```

## Browser Compatibility

Works best on modern browsers that support WebGL:
- Chrome (recommended)
- Firefox
- Safari
- Edge

## Customization

You can easily customize the website by modifying:
- **Colors**: Edit the `colors` array in `script.js`
- **Shapes**: Add more geometries in the shape button click handler
- **Particle count**: Modify `particlesCount` variable
- **Animation speed**: Adjust `rotationSpeed` variable

## License

Free to use and modify for personal and commercial projects.
