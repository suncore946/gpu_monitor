import torch
import time
import os
import sys
import argparse
import multiprocessing

def gpu_stress_task(gpu_id, duration, mem_gb):
    """
    单个 GPU 的压测任务函数
    """
    try:
        # 在 spawn 模式下，子进程进入函数时才真正初始化 CUDA
        torch.cuda.set_device(gpu_id)
        
        pid = os.getpid()
        print(f"[{gpu_id}] 🚀 启动压测 | PID: {pid}")
        print(f"[{gpu_id}] 💾 尝试分配显存: {mem_gb}GB")

        # 1. 显存占位
        try:
            # 1GB float32 ≈ 2.68亿个元素 (1024*1024*256)
            tensor_size = (int(mem_gb * 256), 1024, 1024)
            x = torch.rand(tensor_size, device=f'cuda:{gpu_id}')
            print(f"[{gpu_id}] ✅ 显存分配成功")
        except RuntimeError as e:
            print(f"[{gpu_id}] ❌ 显存不足或出错: {e}")
            return

        # 2. 计算负载
        print(f"[{gpu_id}] 🔥 开始矩阵运算...")
        
        # 创建计算矩阵 (4000x4000 适合产生高负载)
        compute_tensor = torch.randn(4000, 4000, device=f'cuda:{gpu_id}')
        
        start_time = time.time()
        while time.time() - start_time < duration:
            torch.mm(compute_tensor, compute_tensor)
            
        print(f"[{gpu_id}] ✅ 测试完成")

    except Exception as e:
        print(f"[{gpu_id}] ❌ 错误: {e}")

def main():
    parser = argparse.ArgumentParser(description="多卡 GPU 并发压力测试脚本")
    parser.add_argument('--duration', type=int, default=60, help='持续时间 (秒)')
    parser.add_argument('--mem_gb', type=int, default=4, help='每张卡占用的显存大小 (GB)')
    parser.add_argument('--gpus', type=str, default='all', help='指定 GPU ID (如 "0,1" 或 "all")')
    args = parser.parse_args()

    # 简单的检查，注意主进程尽量少调用 CUDA 函数，或者确保调用前已设置 spawn
    if not torch.cuda.is_available():
        print("❌ 错误: 未检测到 CUDA 环境")
        sys.exit(1)

    total_gpus = torch.cuda.device_count()
    
    # 解析目标 GPU
    if args.gpus == 'all':
        target_gpus = list(range(total_gpus))
    else:
        target_gpus = [int(x) for x in args.gpus.split(',')]

    print(f"========================================")
    print(f"🎯 目标显卡: {target_gpus}")
    print(f"⏳ 持续时间: {args.duration}s | 显存: {args.mem_gb}GB")
    print(f"========================================")

    processes = []
    
    for gpu_id in target_gpus:
        p = multiprocessing.Process(
            target=gpu_stress_task, 
            args=(gpu_id, args.duration, args.mem_gb)
        )
        p.start()
        processes.append(p)

    for p in processes:
        p.join()

    print("✅ 所有测试结束")

if __name__ == "__main__":
    # 【关键修改】设置启动方法为 spawn
    # 必须放在 if __name__ == "__main__": 的第一行
    try:
        multiprocessing.set_start_method('spawn')
    except RuntimeError:
        # 如果已经设置过（例如在某些环境中），则忽略错误
        pass
    
    main()

