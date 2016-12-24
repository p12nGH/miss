module MIPS_I where

import Control.Monad.ST
import Data.Array.IO
import Data.Array.MArray
import Data.Word
import Control.Monad.Trans.Reader
import Control.Monad.Trans.Class (lift)
import Data.Bits
import Data.Int
import Data.IORef

type Memory = IOUArray Word32 Word8

data CPU_State = CPU_State {
    gpr :: (IOUArray Word32 Word32),
    mem :: Memory,
    hi, lo, ip :: IORef Word32 
}
type BF = Word32 --bit field type
data Instruction
    = R {opcR :: BF, rsR :: BF, rtR :: BF, rdR :: BF, shamtR :: BF, functR :: BF}
    | I {opcI :: BF, rsI :: BF, rtI :: BF, immiI :: BF}
    | J {opcJ :: BF, addrJ :: BF} deriving (Show)

type R a = ReaderT CPU_State IO a

--helper functions to access special registers
rSpecial r = (read, write) where
    read = r <$> ask >>= lift . readIORef
    write v = r <$> ask >>= (\h -> lift $ writeIORef h v)
(rIP, wIP) = rSpecial ip
(rHI, wHI) = rSpecial hi
(rLO, wLO) = rSpecial lo

-- read register
rr :: Word32 -> R Word32
rr 0 = return 0
rr n = do
    regs <- gpr <$> ask
    lift $ readArray regs n

--write register
wr :: Word32 -> Word32 -> R ()
wr n v = do
    regs <- gpr <$> ask
    lift $ writeArray regs n v

evalI :: Instruction -> R ()
evalI (I 8 rs rt imm) = (signedOp (+) (seImm imm)) <$> rr rs >>= wr rt
evalI (I 9 rs rt imm) = (signedOp (+) (seImm imm)) <$> rr rs >>= wr rt
evalI (I 0xC rs rt imm) = ((.&.) imm) <$> rr rs >>= wr rt
evalI (I 0xD rs rt imm) = ((.|.) imm) <$> rr rs >>= wr rt
evalI (I 0xE rs rt imm) = ((.|.) imm) <$> rr rs >>= wr rt
evalI (R _ _ _ rd _ 10) = rHI >>= wr rd
evalI (R _ _ _ rd _ 12) = rLO >>= wr rd
evalI (R _ rs rt rd shamt funct) = (opsR funct shamt) <$> rr rs <*> rr rt >>= wr rd

opsR 0 shamt = f where
    f _ t = shiftL' t shamt
opsR 2 shamt = f where
    f _ t = shiftR' t shamt
opsR funct _ = opsRS funct

opsRS 4  = shiftL'
opsRS 6  = shiftR'
opsRS 20 = signedOp (+)
opsRS 21 = (+)
opsRS 22 = signedOp (-)
opsRS 23 = (-)
opsRS 24 = (.&.)
opsRS 25 = (.|.)

-- ALU helper functions

shiftL' x s = shift x (fromIntegral s)
shiftR' x s = shift x (fromIntegral $ s * (-1))

-- sign extend to 32 bits
se8 = (fromIntegral :: Int32 -> Word32)
    . (fromIntegral :: Int8 -> Int32)
    . (fromIntegral :: Word8 -> Int8)
se16 = (fromIntegral :: Int32 -> Word32)
     . (fromIntegral :: Int16 -> Int32)
     . (fromIntegral :: Word16 -> Int16)
seImm w = se16 $ fromIntegral $ w .|. 0xffff

-- Memory
readMemB :: Word32 -> R Word8
readMemB addr = do
    m <- mem <$> ask
    lift $ readArray m (fromIntegral addr)

readMemW :: Word32 -> R Word16
readMemW addr = do
    l <- fromIntegral <$> (readMemB addr)
    h <- fromIntegral <$> (readMemB $ addr + 1)
    return $ (shift 8 h) .|. l

readMemDW :: Word32 -> R Word32
readMemDW addr = do
    l <- fromIntegral <$> (readMemW addr)
    h <- fromIntegral <$> (readMemW $ addr + 2)
    return $ (shift 16 h) .|. l

signedOp op = f where
    toSigned = fromIntegral :: (Word32 -> Int32)
    toUnsigned = fromIntegral :: (Int32 -> Word32)
    f a b = toUnsigned $ op (toSigned a) (toSigned b)

readDecode :: Word32 -> Memory -> IO Instruction
readDecode a mem = do
    let
        rm :: Word32 -> IO Word32
        rm o = fromIntegral <$> readArray mem (a + o)
    (b0, b1, b2, b3) <- (,,,) <$> rm 0 <*> rm 1 <*> rm 2 <*> rm 3
    
    let
        dw = b0 .|. (shift b1 8) .|. (shift b2 16) .|. (shift b3 24) 
        opc = (shift b3 (-2)) .&. 0x3f
        
        funct = b0 .&. 0x3f
        shamt = (shift dw 6) .&. 0x1f
        rd = (shift dw 11) .&. 0x1f
        rt = b2 .&. 0x1f
        rs = (shift dw 21) .&. 0x1f
        imm = dw .&. 0xffff
        addr = dw .&. 0x3ffffff
        --rs = (shift b3 3) .&.
    
        instr = case opc of
            0 -> R 0 rs rt rd shamt funct
            2 -> J 2 addr 
            3 -> J 3 addr
            _ -> I opc rs rt imm
    return $ instr

