const sharp = require('sharp');
const fs = require('fs');
const path = require('path');

const srcSvg = 'docs/design/icon/easysave-icon-C/svg/bubble-arrow-24.svg';
const basePath = 'app/android/app/src/main/res';

const densities = [
  { folder: 'drawable-mdpi', size: 24 },
  { folder: 'drawable-hdpi', size: 36 },
  { folder: 'drawable-xhdpi', size: 48 },
  { folder: 'drawable-xxhdpi', size: 72 },
  { folder: 'drawable-xxxhdpi', size: 96 },
];

(async () => {
  const svgBuffer = fs.readFileSync(srcSvg);
  
  for (const { folder, size } of densities) {
    const outputDir = path.join(basePath, folder);
    if (!fs.existsSync(outputDir)) {
      fs.mkdirSync(outputDir, { recursive: true });
    }
    
    const outputFile = path.join(outputDir, 'ic_stat_easysave.png');
    
    await sharp(svgBuffer)
      .resize(size, size)
      .png()
      .toFile(outputFile);
    
    console.log(`Generated: ${outputFile} (${size}x${size}px)`);
  }
  
  console.log('\nAll notification icons generated successfully!');
})();
