{-# LANGUAGE ScopedTypeVariables #-}
{-| Draw and update waterfall plots with OpenGL. Useful for spectrograms.

Example usage:

> import Control.Monad
> import Control.Monad.Trans.Either
> import Control.Concurrent
> import Pipes
> import qualified Pipes.Prelude as P
> import System.Random
> import Graphics.Rendering.OpenGL
> 
> import Graphics.DynamicGraph.Waterfall
> 
> randomVect :: Producer [GLfloat] IO ()
> randomVect =  P.repeatM $ do
>     res <- replicateM 1000 randomIO
>     threadDelay 10000
>     return res
> 
> main = eitherT putStrLn return $ do
>     setupGLFW
>     waterfall <- waterfallWindow 1024 480 1000 1000 jet_mod
> 
>     lift $ runEffect $ randomVect >-> waterfall
-}
module Graphics.DynamicGraph.Waterfall (
    renderWaterfall,
    setupGLFW,
    module Graphics.DynamicGraph.ColorMaps
    ) where

import Control.Monad
import Control.Concurrent hiding (yield)
import Control.Concurrent.MVar
import Graphics.UI.GLFW as G
import Graphics.Rendering.OpenGL
import Graphics.GLUtil

import Control.Monad.Trans.Class
import Control.Monad.Trans.Either
import Foreign.Storable
import Foreign.Marshal.Array
import Data.IORef

import Pipes

import Graphics.DynamicGraph.Util
import Graphics.DynamicGraph.ColorMaps

import Paths_dynamic_graph

{-| @(renderWaterfallLine width height colorMap)@ returns a Consumer that
    renders a waterfall plot into the current OpenGL context. The Consumer
    takes data that is an instance of IsPixelData and of length @width@.
    The waterfall is @height@ rows of data high.

    The fill is drawn with a vertical gradient defined by @colorMap@.

    All OpenGL based initialization of the rendering function (loading of
    shaders, etc) is performed before the pipe is returned.
-}
renderWaterfall :: IsPixelData a => Int -> Int -> [GLfloat] -> IO (Consumer a IO ())
renderWaterfall width height colorMap = do
    --Load the shaders
    vertFN <- getDataFileName "shaders/waterfall.vert"
    fragFN <- getDataFileName "shaders/waterfall.frag"
    vs <- loadShader VertexShader   vertFN
    fs <- loadShader FragmentShader fragFN
    p  <- linkShaderProgram [vs, fs]

    --Set stuff
    currentProgram $= Just p

    ab <- genObjectName 

    locc <- get $ attribLocation p "coord"

    let stride = fromIntegral $ sizeOf (undefined::GLfloat) * 2
        vad    = VertexArrayDescriptor 2 Float stride offset0

    bindBuffer ArrayBuffer  $= Just ab
    vertexAttribArray   locc $= Enabled
    vertexAttribPointer locc $= (ToFloat, vad)

    let xCoords :: [GLfloat]
        xCoords = [-1, -1, 1, -1, 1, 1, -1, 1]
    withArray xCoords $ \ptr -> 
        bufferData ArrayBuffer $= (fromIntegral $ sizeOf(undefined::GLfloat) * 8, ptr, StaticDraw)

    let yCoords :: [GLfloat]
        yCoords = take (width * height) $ repeat 0

    activeTexture $= TextureUnit 0
    texture Texture2D $= Enabled
    to0 <- loadTexture (TexInfo (fromIntegral width) (fromIntegral height) TexMono yCoords)
    
    loc <- get $ uniformLocation p "texture"
    asUniform (0 :: GLint) loc

    textureFilter Texture2D $= ((Linear', Nothing), Linear')
    textureWrapMode Texture2D S $= (Repeated, ClampToEdge)
    textureWrapMode Texture2D T $= (Repeated, Repeat)

    activeTexture $= TextureUnit 1
    texture Texture2D $= Enabled
    to1 <- loadTexture (TexInfo (fromIntegral $ length colorMap `quot` 3) 1 TexRGB colorMap)
    textureFilter Texture2D $= ((Linear', Nothing), Linear')
    textureWrapMode Texture2D S $= (Repeated, ClampToEdge)
    textureWrapMode Texture2D T $= (Repeated, ClampToEdge)

    loc <- get $ uniformLocation p "colorMap"
    asUniform (1 :: GLint) loc 

    let lcm :: GLfloat
        lcm = fromIntegral $ length colorMap `quot` 3
    loc <- get $ uniformLocation p "scale"
    asUniform ((lcm - 1) / lcm) loc 

    loc <- get $ uniformLocation p "offset"
    asUniform (0.5 / lcm) loc 

    loc <- get $ uniformLocation p "voffset"

    let pipe yoffset = do
            dat <- await

            lift $ do
                currentProgram $= Just p

                let textureOffset = (yoffset + height - 1) `mod` height

                withPixels dat $ \ptr -> 
                    texSubImage2D Texture2D 0 (TexturePosition2D 0 (fromIntegral textureOffset)) (TextureSize2D (fromIntegral width) 1) (PixelData Red Float ptr)

                asUniform (fromIntegral yoffset / fromIntegral height :: GLfloat) loc

                bindBuffer ArrayBuffer   $= Just ab
                vertexAttribArray   locc $= Enabled
                vertexAttribPointer locc $= (ToFloat, vad)

                activeTexture $= TextureUnit 0
                textureBinding Texture2D $= Just to0

                activeTexture $= TextureUnit 1
                textureBinding Texture2D $= Just to1

                --No idea why this is needed
                activeTexture $= TextureUnit 0

                drawArrays Quads 0 4

            pipe $ if yoffset + 1 >= height then 0 else yoffset + 1

    return $ pipe 0

