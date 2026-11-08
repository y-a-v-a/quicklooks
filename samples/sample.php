<?php
/*
 * Block comment spanning lines: function, return and $notAVariable stay comment.
 */
declare(strict_types=1);

namespace App\Orders;

use App\Models\Order;

final class OrderService
{
    private const BASE_URL = 'https://example.com/api#v2'; // # and // inside a string
    # a hash comment

    public function __construct(private readonly array $config = []) {}

    public function label(Order $order): string
    {
        $total = $order->total ?? 0.0;
        return "Order {$order->id}: " . number_format($total, 2);
    }

    public function find(int $id): ?Order
    {
        foreach ($this->config['orders'] as $key => $value) {
            if ($value['id'] === $id && isset($value['total'])) {
                return new Order($value);
            }
        }
        return null;
    }
}
