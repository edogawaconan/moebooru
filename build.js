#!/usr/bin/env node

import babel from '@babel/core';
import { createHash } from 'crypto';
import esbuild from 'esbuild';
import coffeeScriptPlugin from 'esbuild-coffeescript';
import { lessLoader } from 'esbuild-plugin-less';
import fsPromises from 'fs/promises';
import { globSync } from 'glob';

const outdir = 'app/assets/builds';

const plugins = [
  coffeeScriptPlugin({
    bare: true,
    inlineMap: true
  }),
  lessLoader({
    rootpath: '',
    sourceMap: {
      sourceMapFileInline: false
    }
  }),
  {
    name: 'babel',
    setup (build) {
      build.onEnd(async () => {
        const esbuildFilepath = `${outdir}/application.js`;
        const inputSourceMap = JSON.parse(await fsPromises.readFile(`${esbuildFilepath}.map`));
        const options = {
          inputSourceMap,
          minified: true,
          presets: [
            ['@babel/preset-env']
          ],
          sourceMaps: true
        };
        const esbuildOutput = await fsPromises.readFile(esbuildFilepath);
        const result = await babel.transformAsync(esbuildOutput, options);
        const filename = 'application.jsout';
        const outfileBabel = `${outdir}/${filename}`;
        result.map.sources = result.map.sources
          // CoffeeScript sourcemap and Esbuild sourcemap combined generates duplicated source paths
          .map((path) => path.replace(/\.\.\/\.\.\/javascript(\/.+)?\/app\/javascript\//, '../../javascript/'));
        const resultMap = JSON.stringify(result.map);
        const resultMapHash = createHash('sha256').update(resultMap).digest('hex');

        // add hash so it matches sprocket output
        fsPromises.writeFile(outfileBabel, `${result.code}\n//# sourceMappingURL=${filename}-${resultMapHash}.map`);
        fsPromises.writeFile(`${outfileBabel}.map`, JSON.stringify(result.map));
      });
    }
  },
  {
    name: 'analyze',
    setup (build) {
      build.onEnd(async (result) => {
        if (options.analyze) {
          const analyzeResult = await esbuild.analyzeMetafile(result.metafile);

          console.log(analyzeResult);
        }
      });
    }
  },
  {
    name: 'log',
    setup (build) {
      let startTime = Date.now();

      build.onStart(() => {
        startTime = Date.now();
        console.log(new Date(), 'Build started');
      });
      build.onEnd(() => {
        console.log(new Date(), `Build finished (${Date.now() - startTime}ms)`);
      });
    }
  }
];

const args = process.argv.slice(2);
const options = {
  watch: args.includes('--watch'),
  analyze: args.includes('--analyze')
};

const config = {
  bundle: true,
  entryPoints: globSync('app/javascript/*.*'),
  external: ['*.gif', '*.png'],
  metafile: options.analyze,
  nodePaths: ['app/javascript'],
  outdir,
  plugins,
  resolveExtensions: ['.coffee', '.js'],
  sourcemap: 'external'
};

if (options.watch) {
  (await esbuild.context(config)).watch();
} else {
  esbuild.build(config);
}
